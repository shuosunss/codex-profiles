(async () => {
  'use strict';
  const key = '__codexProfilesConversationSync';
  const version = 1;
  if (window.electronBridge?.windowType !== 'electron' || !window.__codexRoot) {
    return { status: 'waiting-for-app' };
  }

  let state = window[key];
  if (state?.version !== version) {
    state?.dispose?.();
    state = {
      version,
      status: 'waiting-for-services',
      lastAttempt: 0,
      lastRefresh: 0,
      pending: null,
      runtime: null,
      disposed: false,
      dispose() { this.disposed = true; },
    };
    window[key] = state;
  }

  // The host also ticks hidden windows, where Chromium may throttle JavaScript timers.
  if (state.pending) return state.pending;
  if (Date.now() - state.lastAttempt < 5000) {
    return { status: state.status, lastRefresh: state.lastRefresh };
  }
  state.lastAttempt = Date.now();
  state.pending = refresh();
  try { return await state.pending; }
  finally { state.pending = null; }

  async function refresh() {
    let manager = null;
    try {
      if (!state.runtime) {
        // Reuse the already-loaded application module. No installed files are modified.
        for (const script of document.querySelectorAll('script[type="module"][src]')) {
          const url = new URL(script.src, location.href);
          if (url.protocol !== location.protocol || url.host !== location.host) continue;
          const module = await import(url.href);
          if (typeof module.__webpack_require__ === 'function') {
            state.runtime = module.__webpack_require__;
            break;
          }
        }
      }
      if (!state.runtime) return result('waiting-for-services');
      const services = state.runtime('GaA7').appServices;
      if (!services?.appServerManagers) return result('waiting-for-services');
      const opened = await services.appServerManagers.open('local');
      manager = opened.manager;
      if (opened.status !== 'ready' || !manager) return result('waiting-for-services');
      if (state.disposed) return result('stopped');

      // Routine refresh is skipped in catalog mode. Expanded refresh reads the shared state DB.
      await manager.refreshRecentConversations({ mode: 'expanded', afterCurrent: true });
      if (state.disposed) return result('stopped');
      await services.queryCache.invalidateQueryCache({
        queryKey: ['recent-conversations-meta'],
        reset: false,
      });
      state.lastRefresh = Date.now();
      return result('ready');
    }
    catch { return result('retrying'); }
    finally {
      // Release the RPC capability obtained for this refresh, including failed attempts.
      manager?.[Symbol.dispose]?.();
    }
  }

  function result(status) {
    state.status = status;
    return { status, lastRefresh: state.lastRefresh };
  }
})()
