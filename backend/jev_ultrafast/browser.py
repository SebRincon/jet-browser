"""Extracted observed-action executor using Jet's private native CEF bridge."""

import hashlib
import json
import sys
import time
from pathlib import Path


# Atomically read visible content and controls, preserving actual DOM node identity.
READ_STATE = Path(__file__).with_name("snapshot.js").read_text()
MARKER = f"(() => {{ const state={READ_STATE}; return state?.marker ?? null; }})()"


class StalePage(ValueError):
    """A decision no longer refers to the observed page."""


class InputNotDelivered(RuntimeError):
    """Chromium acknowledged native input that never reached the observed target.

    Raised instead of continuing, so no text is typed into another element and the
    same click is not repeated; the probe details go to input diagnostics.
    """


# Capture listeners record where pointer moves and the press actually land. The
# click is sent only after a harmless move reached the target, so misrouted native
# input cannot press another control. The probe runs in the page: a hostile page can
# only make delivery look failed, which stops the task (fail-safe).
_PROBE_ARM = """(node => {
  const target = window.__jevFast?.nodes.get(node);
  const onTarget = hit => !!target && !!hit && (target === hit || target.contains(hit) ||
    [...(target.labels || [])].some(label => label.contains(hit)));
  const probe = {moved: false, move_on_target: false, pressed: false};
  const listener = event => {
    const hit = event.target;
    if (event.type === 'mousemove') {
      probe.moved = true;
      probe.move_on_target = probe.move_on_target || onTarget(hit);
      probe.move_x = event.clientX;
      probe.move_y = event.clientY;
      probe.move_tag = hit?.tagName || null;
    } else if (!probe.pressed) {
      probe.pressed = true;
      probe.on_target = onTarget(hit);
      probe.x = event.clientX;
      probe.y = event.clientY;
      probe.tag = hit?.tagName || null;
    }
  };
  addEventListener('mousemove', listener, true);
  addEventListener('mousedown', listener, true);
  window.__jevInputProbe = {probe, listener, target};
  return true;
})(%s)"""
_PROBE_PEEK = "(() => ({...(window.__jevInputProbe?.probe || {})}))()"
_PROBE_READ = """(() => {
  const armed = window.__jevInputProbe;
  if (!armed) return null;
  removeEventListener('mousemove', armed.listener, true);
  removeEventListener('mousedown', armed.listener, true);
  delete window.__jevInputProbe;
  const active = document.activeElement, viewport = window.visualViewport;
  return {...armed.probe,
    focused: !!armed.target && !!active && (active === armed.target || armed.target.contains(active)),
    active_tag: active?.tagName || null,
    viewport: viewport ? {x: viewport.offsetLeft, y: viewport.offsetTop, scale: viewport.scale} : null,
    device_pixel_ratio: devicePixelRatio,
    visibility: document.visibilityState};
})()"""


class Browser:
    def __init__(self, url=None, transport=None):
        if transport is None:
            raise ValueError("An exact native browser tab is required")
        self.transport = transport
        self.session = transport
        self.target = transport.tab_id

    def call(self, method, **params):
        return self.transport.call(method, **params)

    def evaluate(self, expression):
        response = self.call("Runtime.evaluate", expression=expression, returnByValue=True)
        if response.get("exceptionDetails"):
            raise StalePage("Document changed during evaluation")
        return response.get("result", {}).get("value")

    def observe(self, screenshot=True):
        if getattr(self, "after_input", None):
            action, self.after_input = self.after_input, None
            # This is read-only and happens after execution was logged, even if navigation interrupts it.
            try:
                self.call(
                    "Runtime.evaluate",
                    expression="""(action => new Promise(resolve => {
                      const field=window.__jevFast?.nodes.get(action.node);
                      const autocomplete=action.kind==='fill' && field?.getAttribute('role')==='combobox';
                      let frames=0, stopped=false;
                      const finish=()=>{stopped=true;resolve()};
                      setTimeout(finish,autocomplete ? 200 : 50);
                      const ready=()=>{
                        if (stopped) return;
                        const ids=(field?.getAttribute('aria-controls')||field?.getAttribute('aria-owns')||'')
                          .split(/\\s+/).filter(Boolean);
                        const roots=ids.length ? ids.map(id=>document.getElementById(id)).filter(Boolean) : [document];
                        const options=roots.flatMap(root=>[...root.querySelectorAll('[role="option"]')]);
                        if (++frames>=2 && (!autocomplete || options.some(e=>{
                          const r=e.getBoundingClientRect();
                          return r.width && r.height && r.bottom>0 && r.top<innerHeight &&
                            e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true});
                        }))) finish();
                        else requestAnimationFrame(ready);
                      };
                      requestAnimationFrame(ready);
                    }))("""
                    + json.dumps(action)
                    + ")",
                    awaitPromise=True,
                    returnByValue=True,
                )
            except RuntimeError:
                pass
        for attempt in range(10):
            try:
                return browser_operation({"operation": "observe", "session": self.session, "screenshot": screenshot})
            except StalePage:
                if attempt == 9:
                    raise
                time.sleep(0.02)
        raise StalePage("Page did not settle")

    def fresh(self, page, action=None):
        if action is not None and action["kind"] in {"click", "select"}:
            node = action["node"]
            if type(node) is not int:
                return False
            current = self.evaluate(
                "(() => { const c=window.__jevFast; "
                f"return c ? [c.pageKey(),c.guard(c.nodes.get({node}))] : null; }})()"
            )
            return current == [page["page_key"], page["guards"].get(str(node))]
        return self.evaluate(MARKER) == page["marker"]

    def act(self, action, page, text=None):
        if self.transport.stopped.is_set():
            raise RuntimeError("Stopped before browser input")
        self.transport.action_active = True
        self.transport.input_started = False
        try:
            return self._act(action, page, text)
        finally:
            self.transport.action_active = False
            self.transport.input_started = False

    def _act(self, action, page, text=None):
        if not self.fresh(page, action):
            raise StalePage("Page changed since this decision. Observe again.")
        if action["kind"] == "wait":
            time.sleep(0.1)
        result = browser_operation({"operation": "act", "session": self.session, "action": action, "text": text})
        self.after_input = action if action["kind"] != "wait" else None
        return result

    def close(self):
        # The native UI owns tab lifetime. Finishing a task never closes its page.
        self.target = None


def fingerprint(state):
    content = {k: state[k] for k in ("url", "text", "actions", "scroll")}
    return hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()


def _record_probe(session, action, probe, x, y, stage):
    safe = {key: probe.get(key) for key in (
        "moved", "move_on_target", "move_x", "move_y", "move_tag", "pressed", "on_target", "x", "y", "tag",
        "focused", "active_tag", "viewport", "device_pixel_ratio", "visibility") if key in probe}
    safe["expected"] = {"x": x, "y": y}
    session.input_diagnostics.append({"method": "input.probe", "stage": stage, "kind": action["kind"], "probe": safe})
    return safe


def _check_pointer(session, evaluate, action, x, y):
    """Refuse to press unless a harmless pointer move reached the observed target."""
    probe = evaluate(_PROBE_PEEK) or {}
    if probe.get("move_on_target"):
        return
    _record_probe(session, action, probe, x, y, "pointer")
    try:
        evaluate(_PROBE_READ)  # Disarm; the page stays untouched.
    except StalePage:
        pass
    if getattr(session, "trace", None):
        session.trace.emit("browser.input.probe", tab_id=session.tab_id, status="error",
                           reason="pointer_missed" if probe.get("moved") else "pointer_not_delivered")
    if not probe.get("moved"):
        raise InputNotDelivered(
            "Chromium acknowledged pointer movement, but the page received none; "
            "the click was not sent and nothing was typed.")
    raise InputNotDelivered(
        f"The pointer arrived over {probe.get('move_tag')} at ({probe.get('move_x')}, {probe.get('move_y')}) "
        f"instead of the target at ({round(x)}, {round(y)}); the click was not sent and nothing was typed.")


def _check_delivery(session, evaluate, action, x, y):
    try:
        probe = evaluate(_PROBE_READ)
    except StalePage:
        return  # The click replaced the document (e.g. a link); delivery is implied.
    if probe is None:
        return  # A new document has no armed probe: the click navigated.
    _record_probe(session, action, probe, x, y, "press")
    if getattr(session, "trace", None):
        session.trace.emit("browser.input.probe", tab_id=session.tab_id, status="ok" if probe.get("on_target") else "error",
                           reason=None if probe.get("on_target") else ("missed_target" if probe.get("pressed") else "not_delivered"))
    if not probe.get("pressed"):
        raise InputNotDelivered(
            "Chromium acknowledged the click, but the page received no mouse press "
            f"(page {probe.get('visibility')}); nothing was typed and the click was not retried.")
    if not probe.get("on_target"):
        raise InputNotDelivered(
            f"The click landed on {probe.get('tag')} at ({probe.get('x')}, {probe.get('y')}) instead of "
            f"the target at ({round(x)}, {round(y)}); nothing was typed and the click was not retried.")
    if action["kind"] == "fill" and not probe.get("focused"):
        raise InputNotDelivered(
            f"The field did not receive focus ({probe.get('active_tag')} is focused); no text was typed.")


def browser_operation(request):
    operation = request["operation"]
    session = request["session"]

    def call(method, **params):
        result = session.call(method, **params)
        if method.startswith("Input."):
            diagnostic = session.call("Runtime.evaluate", expression="({focus:document.hasFocus(),tag:document.activeElement?.tagName,id:document.activeElement?.id,type:document.activeElement?.type})", returnByValue=True)
            focus = diagnostic.get("result", {}).get("value") or {}
            safe_focus = {key: focus.get(key) for key in ('focus', 'tag', 'type')}
            session.input_diagnostics.append({"method": method, "focus": safe_focus})
            if getattr(session, 'trace', None):
                session.trace.emit('browser.input.focus', method=method, tab_id=session.tab_id, **safe_focus)
        return result

    def evaluate(expression):
        result = call("Runtime.evaluate", expression=expression, returnByValue=True)
        if result.get("exceptionDetails"):
            if operation == "act" and request["action"]["kind"] == "select":
                raise RuntimeError("Dropdown execution was interrupted; inspect before retrying.")
            raise StalePage("Document changed during evaluation")
        return result.get("result", {}).get("value")

    if operation == "act":
        action = request["action"]
        kind = action["kind"]
        if kind == "scroll":
            call("Input.dispatchMouseEvent", type="mouseWheel", x=550, y=650, deltaX=0, deltaY=action["delta"])
        elif kind != "wait":
            if type(action["node"]) is not int:
                raise ValueError("Invalid observed node")
            # Code-owned node IDs refer to actual observed elements, never model-generated selectors.
            target = evaluate(
                """(action => {
              const e=window.__jevFast?.nodes.get(action.node);
              if (!e?.isConnected || e.matches(':disabled') || e.closest('[aria-disabled="true"],[inert]') ||
                  !e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return null;
              if (action.kind==='fill' && (e.readOnly || e.getAttribute('aria-readonly')==='true')) return null;
              const r=e.getBoundingClientRect(), x=r.x+r.width/2, y=r.y+r.height/2;
              if (!r.width || !r.height || x<0 || y<0 || x>=innerWidth || y>=innerHeight) return null;
              if (!e.contains(document.elementFromPoint(x,y))) return null;
              if (action.kind==='select') {
                if (e.tagName!=='SELECT' || ![...e.options].some(o=>o.value===action.value &&
                    !o.disabled && !o.closest('optgroup[disabled]'))) return null;
                e.value=action.value;
                e.dispatchEvent(new Event('input',{bubbles:true}));
                e.dispatchEvent(new Event('change',{bubbles:true}));
              }
              return {x,y};
            })("""
                + json.dumps(action)
                + ")"
            )
            if target is None:
                if kind == "select":
                    raise RuntimeError("Dropdown execution was not confirmed; inspect before retrying.")
                raise StalePage("Target changed or is covered. Observe again.")
            if kind != "select":
                x, y = target["x"], target["y"]
                evaluate(_PROBE_ARM % json.dumps(action["node"]))
                # Two moves guarantee a position change, so Chromium emits mousemove.
                for dy in (-1, 0):
                    call("Input.dispatchMouseEvent", type="mouseMoved", x=x, y=y + dy)
                _check_pointer(session, evaluate, action, x, y)
                for event in ("mousePressed", "mouseReleased"):
                    call("Input.dispatchMouseEvent", type=event, x=x, y=y, button="left", clickCount=1)
                _check_delivery(session, evaluate, action, x, y)
                if kind == "fill":
                    call(
                        "Input.dispatchKeyEvent",
                        type="keyDown",
                        key="a",
                        code="KeyA",
                        modifiers=4 if sys.platform == "darwin" else 2,
                        commands=["selectAll"],
                    )
                    call(
                        "Input.dispatchKeyEvent",
                        type="keyUp",
                        key="a",
                        code="KeyA",
                        modifiers=4 if sys.platform == "darwin" else 2,
                    )
                    call("Input.insertText", text=request["text"])
        return {"executed": action["id"]}

    info = evaluate(READ_STATE)
    if info is None:
        raise StalePage("Document is navigating")
    info["fingerprint"] = fingerprint(info)
    if request.get("screenshot", True):
        info["screenshot"] = call("Page.captureScreenshot", format="jpeg", quality=72)["data"]
    return info
