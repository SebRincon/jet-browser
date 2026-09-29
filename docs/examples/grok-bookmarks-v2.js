// Real Grok-authored synthetic acceptance workflow. Requires the Jet SDK.
function listSaved() {
  var listed = jet.call('records.list', { limit: 20, offset: 0 }) || {};
  var items = listed.items || [];
  var ids = {};
  var i;
  for (i = 0; i < items.length; i++) {
    var row = items[i] || {};
    if (row.item_id) ids[String(row.item_id)] = true;
    if (row.id) ids[String(row.id)] = true;
    if (row.url) ids[String(row.url)] = true;
  }
  var total = typeof listed.total === 'number' ? listed.total : items.length;
  return { ids: ids, total: total };
}

function isSaved(saved, item) {
  if (!item) return true;
  if (item.id && saved.ids[String(item.id)]) return true;
  if (item.url && saved.ids[String(item.url)]) return true;
  return false;
}

function saveItem(item) {
  if (item.truncated) {
    var recovered = jet.call('post.recover', { item_id: item.id }) || {};
    if (recovered.blocked) {
      jet.call('run.progress', { message: 'Recovery blocked for a bookmark' });
      return false;
    }
  }
  var classified = jet.call('model.classify', { item_id: item.id }) || {};
  var summarized = jet.call('model.summarize', { item_id: item.id }) || {};
  jet.call('records.put', {
    item_id: item.id,
    tags: classified.tags || [],
    summary: summarized.summary || ''
  });
  jet.call('run.progress', { message: 'Saved a bookmark' });
  return true;
}

var saved = listSaved();
var target = saved.total >= 2 ? 3 : 2;
if (saved.total >= 3) {
  jet.call('run.checkpoint', {
    state: { phase: 'done', saved_count: saved.total },
    status: 'complete',
    summary: 'Three unique bookmarks are saved'
  });
} else {
  var observed = jet.call('feed.observe', {}) || {};
  var steps = 0;
  var noProgressScrolls = 0;
  while (saved.total < target && steps < 6 && noProgressScrolls < 2) {
    var items = observed.items || [];
    var i;
    for (i = 0; i < items.length && saved.total < target; i++) {
      var item = items[i];
      if (!item || !item.id) continue;
      if (isSaved(saved, item)) continue;
      if (saveItem(item)) {
        saved.ids[String(item.id)] = true;
        if (item.url) saved.ids[String(item.url)] = true;
        saved.total += 1;
      }
    }
    if (saved.total >= target) break;
    if (observed.end_of_feed === true) break;
    var decision = jet.call('model.decide', {
      question: 'Another unsaved bookmark is still needed. Scroll or stop?',
      choices: {
        scroll: 'Scroll once to reveal another bookmark',
        stop: 'Stop because the feed shows no further bookmarks'
      },
      text: 'visible=' + items.length + ' saved=' + saved.total + ' target=' + target + ' end_of_feed=' + observed.end_of_feed + ' loading=' + observed.loading
    }) || {};
    if (decision.choice !== 'scroll') break;
    var previousId = observed.observation_id;
    var next = jet.call('feed.scroll', { observation_id: observed.observation_id }) || {};
    steps += 1;
    if (next.observation_id && next.observation_id === previousId) noProgressScrolls += 1;
    else noProgressScrolls = 0;
    observed = next;
  }
  if (target === 3 && saved.total >= 3) {
    jet.call('run.checkpoint', {
      state: { phase: 'done', saved_count: saved.total },
      status: 'complete',
      summary: 'Saved the third bookmark'
    });
  } else if (saved.total >= 2 && target === 2) {
    jet.call('run.checkpoint', {
      state: { phase: 'collect_third', saved_count: saved.total },
      status: 'review',
      summary: 'Saved the first two bookmarks for review'
    });
  } else {
    jet.call('run.checkpoint', {
      state: { phase: 'collect_third', saved_count: saved.total },
      status: 'pause',
      summary: 'Stopped before the next unique bookmark was available'
    });
  }
}
