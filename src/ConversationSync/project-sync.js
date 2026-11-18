(serializedSnapshot => {
  'use strict';
  const key = '__codexProfilesSharedProjects';
  if (window.electronBridge?.windowType !== 'electron' || !window.__codexRoot) {
    return { status: 'waiting-for-app' };
  }
  if (!serializedSnapshot && !window[key]) return { status: 'inactive' };

  const queryKey = name => ['vscode', 'get-global-state', JSON.stringify({ key: name })];
  const keys = {
    projects: queryKey('local-projects'),
    memberships: queryKey('thread-project-assignments'),
    order: queryKey('project-order'),
  };
  const projectlessKey = queryKey('projectless-thread-ids');
  if (!window[key]) {
    // Acquire the current renderer's existing QueryClient from its React provider.
    const pending = [window.__codexRoot._internalRoot?.current];
    let client;
    while (pending.length) {
      const fiber = pending.pop();
      if (!fiber) continue;
      const props = fiber.memoizedProps;
      for (const candidate of [props?.client, props?.value?.queryClient, props?.value]) {
        if (typeof candidate?.getQueryCache !== 'function' || typeof candidate?.setQueryData !== 'function') continue;
        client = candidate;
        break;
      }
      if (client) break;
      pending.push(fiber.sibling, fiber.child);
    }
    if (!client) return { status: 'waiting-for-queries' };
    window[key] = { client, inputs: {}, fetched: new WeakMap(), body: null, snapshot: null, applying: false, queued: false };
  }

  const state = window[key];
  if (state.body !== serializedSnapshot) {
    state.snapshot = serializedSnapshot ? JSON.parse(serializedSnapshot) : null;
    state.body = serializedSnapshot;
  }
  const cache = state.client.getQueryCache();
  if (!state.unsubscribe) {
    const names = new Set(Object.values(keys).map(parts => parts[2]));
    names.add(projectlessKey[2]);
    state.unsubscribe = cache.subscribe(event => {
      if (state.applying || event.type !== 'updated' || event.action?.type !== 'success') return;
      const query = event.query.queryKey;
      if (query[0] !== 'vscode' || query[1] !== 'get-global-state' || !names.has(query[2])) return;
      if (!event.action.manual) state.fetched.set(event.query, event.query.state.data);
      if (state.queued) return;
      // Wait for the app's batched query updates before applying the source projection again.
      state.queued = true;
      queueMicrotask(() => {
        state.queued = false;
        try { project(); } catch { /* The next background tick will retry. */ }
      });
    });
  }
  try { return project(); }
  catch { return { status: 'retrying' }; }

  function project() {
    const projects = read('projects');
    const memberships = read('memberships');
    const order = read('order');
    if (!projects) return { status: 'waiting-for-queries' };
    const source = state.snapshot;
    const nativeProjects = projects.base.value ?? {};
    const nativeMemberships = memberships?.base.value ?? {};
    const nativeOrder = order?.base.value ?? [];
    const projectlessIds = state.client.getQueryData(projectlessKey)?.value;
    const projectless = new Set(Array.isArray(projectlessIds) ? projectlessIds : []);
    const addedProjects = {};
    const addedMemberships = {};
    const addedOrder = [];
    if (source) {
      for (const [id, metadata] of Object.entries(source.projects)) {
        if (!Object.hasOwn(nativeProjects, id)) addedProjects[id] = metadata;
      }
      for (const [id, projectId] of Object.entries(source.memberships)) {
        const destinationProject = nativeProjects[projectId];
        if (destinationProject?.chatGptBacking || destinationProject?.chatGptBackingCreation || destinationProject?.retiredChatGptBacking) continue;
        if (!Object.hasOwn(nativeMemberships, id) && !projectless.has(id)) {
          addedMemberships[id] = { projectId, projectKind: 'local' };
        }
      }
      const seen = new Set(nativeOrder);
      for (const id of [...source.order, ...Object.keys(addedProjects)]) {
        if (Object.hasOwn(addedProjects, id) && !seen.has(id)) {
          seen.add(id);
          addedOrder.push(id);
        }
      }
    }

    // Updating these three renderer queries keeps views and drafts open. The app still owns its persisted state.
    state.applying = true;
    try {
      update(projects, addedProjects);
      if (memberships) update(memberships, addedMemberships);
      if (order) update(order, addedOrder);
    }
    finally { state.applying = false; }
    return {
      status: source ? (memberships ? 'ready' : 'waiting-for-memberships') : 'inactive',
      projects: Object.keys(addedProjects).length,
      memberships: memberships ? Object.keys(addedMemberships).length : 0,
    };
  }

  function read(name) {
    const query = cache.find({ queryKey: keys[name], exact: true });
    const data = query?.state.data;
    if (!data || (data.value != null && (name === 'order'
      ? !Array.isArray(data.value)
      : typeof data.value !== 'object' || Array.isArray(data.value)))) return null;
    let input = state.inputs[name];
    const fetched = state.fetched.get(query) === data;
    state.fetched.delete(query);
    if (fetched || input?.query !== query || input.last !== data) {
      let base = data;
      let carried = null;
      // Native optimistic updates may carry over projected fields. Strip only entries carried over by reference.
      if (!fetched && input?.query === query && data.value != null && input.added) {
        carried = input.added;
        if (name === 'order') {
          const donated = new Set(input.added);
          base = { ...data, value: data.value.filter(id => !donated.has(id)) };
        } else {
          const value = { ...data.value };
          for (const id of Object.keys(input.added)) {
            if (value[id] === input.last.value?.[id]) delete value[id];
          }
          base = { ...data, value };
        }
      }
      input = { query, base, last: data, added: carried, signature: '' };
      state.inputs[name] = input;
    }
    return input;
  }

  function update(input, added) {
    const signature = JSON.stringify(added);
    if (input.signature === signature) return;
    const hasAdditions = Object.keys(added).length > 0;
    if (!hasAdditions && input.added == null) return;
    let value = input.base.value;
    if (hasAdditions) {
      value = Array.isArray(added) ? [...(value ?? []), ...added] : { ...value, ...added };
    }
    const query = input.query;
    // Preserve the application's own fetch timestamp and avoid waking existing observers on an unchanged result.
    const data = state.client.setQueryData(query.queryKey, { ...input.base, value }, { updatedAt: query.state.dataUpdatedAt });
    input.last = data;
    input.added = added;
    input.signature = signature;
  }
})
