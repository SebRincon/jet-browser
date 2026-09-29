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
  }
  var total = typeof listed.total === 'number' ? listed.total : items.length;
  return { ids: ids, total: total };
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
if (saved.total >= 2) {
  jet.call('run.checkpoint', {
    state: { phase: 'collect_third', saved_count: saved.total },
    status: 'review',
    summary: 'First two bookmarks are saved for review'
  });
} else {
  var observed = jet.call('feed.observe', {}) || {};
  var items = observed.items || [];
  var take = items.slice(0, 2);
  var i;
  for (i = 0; i < take.length; i++) {
    var item = take[i];
    if (!item || !item.id) continue;
    if (saved.ids[String(item.id)]) continue;
    if (saved.total >= 2) break;
    if (saveItem(item)) {
      saved.ids[String(item.id)] = true;
      saved.total += 1;
    }
  }
  jet.call('run.checkpoint', {
    state: { phase: 'collect_third', saved_count: saved.total },
    status: 'review',
    summary: 'Saved the first two bookmarks for review'
  });
}
