import Foundation

/// App-authored playback inspector injected into each WebKit frame, including
/// cross-origin iframe players. The website cannot be read through the top
/// document's DOM due to same-origin policy; each frame reports its own URLs
/// through WKScriptMessageHandler after a user taps Find Video.
///
/// This does NOT capture browser traffic, decrypt DRM or intercept credentials.
enum UniversalMediaFrameProbe {
    static let handlerName = "viFrameMedia"

    static let script = #"""
    (() => {
      if (window.__videoIntelligenceFrameProbeInstalled) return;
      Object.defineProperty(window, '__videoIntelligenceFrameProbeInstalled',
                            {value:true, configurable:false});
      const mediaPattern = /\.(mp4|m4v|mov|webm|mp3|m4a|aac|m3u8|mpd)$/i;
      const isVideoEmbed = (frame) => {
        const source = String(frame.getAttribute('src') || '').toLowerCase();
        const allow = String(frame.getAttribute('allow') || '').toLowerCase();
        return frame.hasAttribute('allowfullscreen') ||
               allow.includes('fullscreen') ||
               /\/embed\/|\/player\/|video|stream/.test(source);
      };

      const report = (nonce) => {
        const seen = new Set();
        const found = [];
        const classify = (url) => {
          const path = url.pathname.toLowerCase();
          return path.endsWith('.m3u8') ? 'hls'
               : path.endsWith('.mpd') ? 'dash' : 'direct';
        };
        const add = (raw, playing, kindHint, poster) => {
          try {
            if (!raw || typeof raw !== 'string' || raw.length > 8192) return;
            const url = new URL(raw, document.baseURI);
            if (url.protocol !== 'https:' || seen.has(url.href)) return;
            // Anything without a recognizable extension must be backed by a
            // real HTML5 player element; do not treat every resource as video.
            if (!mediaPattern.test(url.pathname) && kindHint !== 'player' &&
                kindHint !== 'embed') return;
            seen.add(url.href);
            found.push({url:url.href,
                        kind:kindHint === 'embed' ? 'embed' : classify(url),
                        playing:!!playing,
                        poster:kindHint === 'player' && poster ? poster : null});
          } catch (_) {}
        };

        try {
          for (const player of document.querySelectorAll('video')) {
            const playing = !player.paused && player.readyState >= 2;
            const poster = player.poster || null;
            add(player.currentSrc, playing, 'player', poster);
            add(player.src, playing, 'player', poster);
            player.querySelectorAll('source[src]').forEach(src => add(src.src, playing, 'player', poster));
          }
          // Unlike the main-frame scanner, this sees metadata belonging to the
          // video HOST's own iframe origin.
          for (const meta of document.querySelectorAll(
            'meta[property="og:video"], meta[property="og:video:url"], meta[name="twitter:player:stream"]'
          )) add(meta.content, false, 'meta');
          for (const resource of performance.getEntriesByType('resource').slice(-350)) {
            const mediaInitiator = ['video', 'audio', 'media'].includes(resource.initiatorType);
            add(resource.name, false, mediaInitiator ? 'player' : 'resource');
          }
          // Offer a user-tapped Open Player fallback for opaque embeds.
          for (const frame of document.querySelectorAll('iframe[src]')) {
            if (isVideoEmbed(frame)) add(frame.src, false, 'embed');
          }
        } catch (_) {}

        try {
          window.webkit.messageHandlers.viFrameMedia.postMessage(JSON.stringify({
            nonce:nonce,
            pageURL:location.href,
            title:String(document.title || 'Embedded video').slice(0,100),
            userAgent:navigator.userAgent,
            candidates:found.slice(0,60)
          }));
        } catch (_) {}
      };

      window.addEventListener('message', (event) => {
        const data = event.data;
        if (!data || data.type !== 'vi.scan.v1' ||
            typeof data.nonce !== 'string' ||
            !/^[A-Fa-f0-9-]{36}$/.test(data.nonce)) return;
        report(data.nonce);
        // A frame can signal its direct children even when the outer page may
        // not inspect those frames' DOM. Depth is bounded to avoid fanout loops.
        const depth = Number.isInteger(data.depth) ? data.depth : 0;
        if (depth >= 6) return;
        for (const frame of [...document.querySelectorAll('iframe')].slice(0, 32)) {
          try { frame.contentWindow?.postMessage({
            type:'vi.scan.v1', nonce:data.nonce, depth:depth+1
          }, '*'); } catch (_) {}
        }
      }, false);
    })();
    """#
}
