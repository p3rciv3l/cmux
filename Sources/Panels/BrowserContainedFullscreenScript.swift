/// Page-world fullscreen presentation confined to the existing browser viewport.
/// This does not implement WebKit's native top layer or CSS `:fullscreen` state.
struct BrowserContainedFullscreenScript {
    static let source = #"""
    (() => {
        if (window.__cmuxContainedFullscreen) return;
        const channel = 'cmux-contained-fullscreen-v1';
        let current = null;
        const stack = [];
        let pending = null;
        let serial = 0;
        let documentID = null;
        const originalFullscreenEnabled = Object.getOwnPropertyDescriptor(Document.prototype, 'fullscreenEnabled') || Object.getOwnPropertyDescriptor(Document.prototype, 'webkitFullscreenEnabled');
        const originalVideoMode = Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, 'webkitPresentationMode');
        const originalVideoFullscreen = Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen');
        const originalSetVideoMode = HTMLVideoElement.prototype.webkitSetPresentationMode;

        function permitted() {
            const policy = document.permissionsPolicy || document.featurePolicy;
            const nativeAllowed = !originalFullscreenEnabled || !originalFullscreenEnabled.get || originalFullscreenEnabled.get.call(document);
            return nativeAllowed && (!policy || typeof policy.allowsFeature !== 'function' || policy.allowsFeature('fullscreen'));
        }
        function activated() {
            return !navigator.userActivation || navigator.userActivation.isActive;
        }
        function failure(element) {
            const error = new TypeError();
            queueMicrotask(() => {
                const target = element && element.isConnected ? element : document;
                target.dispatchEvent(new Event('fullscreenerror', {bubbles: true, composed: true}));
                target.dispatchEvent(new Event('webkitfullscreenerror', {bubbles: true, composed: true}));
            });
            return error;
        }
        function notify(element, video) {
            // Start native chrome layout before running synchronous page handlers.
            // Reentrant changes then report in the same order as their state changes.
            report();
            const target = element && element.isConnected ? element : document;
            target.dispatchEvent(new Event('fullscreenchange', {bubbles: true, composed: true}));
            target.dispatchEvent(new Event('webkitfullscreenchange', {bubbles: true, composed: true}));
            if (video) {
                video.dispatchEvent(new Event('webkitpresentationmodechanged'));
                video.dispatchEvent(new Event(current && current.element === video ? 'webkitbeginfullscreen' : 'webkitendfullscreen'));
            }
        }
        function report() {
            if (window === window.top && documentID) {
                try { window.webkit.messageHandlers.cmuxContainedFullscreen.postMessage({active: !!current, documentID}); } catch (_) {}
            }
        }
        function send(target, action, extra = {}) {
            target.postMessage({channel, action, ...extra}, '*');
        }
        function ancestor(element) {
            return element.parentElement || (element.getRootNode() instanceof ShadowRoot ? element.getRootNode().host : null);
        }
        function changeStyle(state, element, properties) {
            if (!state.styleAttributes.has(element)) state.styleAttributes.set(element, element.hasAttribute('style'));
            for (const [name, value] of Object.entries(properties)) {
                const oldValue = element.style.getPropertyValue(name);
                const oldPriority = element.style.getPropertyPriority(name);
                element.style.setProperty(name, value, 'important');
                state.styles.push({element, name, oldValue, oldPriority, applied: element.style.getPropertyValue(name)});
            }
        }
        const transitionStates = new Map();
        let transitionGeneration = 0;
        let transitionTimer = null;
        function clearTransitionSuppression() {
            ++transitionGeneration;
            clearTimeout(transitionTimer);
            transitionTimer = null;
            for (const state of transitionStates.values()) restore(state);
            transitionStates.clear();
        }
        function suppressTransitionsForPresentation(presentation) {
            const generation = ++transitionGeneration;
            // Only the elements whose geometry we change need suppression.
            // A page-wide stylesheet would invalidate every descendant twice.
            for (const [target, originallyPresent] of presentation.styleAttributes) {
                let state = transitionStates.get(target);
                if (state) {
                    for (const item of state.styles) {
                        const value = target.style.getPropertyValue(item.name);
                        const priority = target.style.getPropertyPriority(item.name);
                        if (value !== item.applied || priority !== 'important') {
                            item.oldValue = value; item.oldPriority = priority;
                        }
                        target.style.setProperty(item.name, '0s', 'important');
                    }
                } else {
                    state = {styles: [], styleAttributes: new Map([[target, originallyPresent]])};
                    changeStyle(state, target, {'transition-duration': '0s', 'transition-delay': '0s'});
                    transitionStates.set(target, state);
                }
            }
            requestAnimationFrame(() => requestAnimationFrame(() => {
                // A previous entry/exit must not end a newer transition's suppression.
                if (transitionGeneration === generation) clearTransitionSuppression();
            }));
            // WebKit can suspend rAF after an iframe returns below the viewport.
            // Bound transient style ownership even when no second frame arrives.
            clearTimeout(transitionTimer);
            transitionTimer = setTimeout(() => {
                if (transitionGeneration === generation) clearTransitionSuppression();
            }, 100);
        }
        function restore(state) {
            state.observer?.disconnect();
            for (const item of state.styles.reverse()) {
                // Preserve changes the page made while presentation was active.
                if (item.element.style.getPropertyValue(item.name) !== item.applied || item.element.style.getPropertyPriority(item.name) !== 'important') continue;
                if (item.oldValue) item.element.style.setProperty(item.name, item.oldValue, item.oldPriority);
                else item.element.style.removeProperty(item.name);
            }
            for (const [element, originallyPresent] of state.styleAttributes) {
                if (!originallyPresent && element.style.length === 0) {
                    // Flush WebKit's lazily synchronized CSSOM attribute before removal.
                    element.getAttribute('style');
                    element.removeAttribute('style');
                }
            }
        }
        function leave(upward = true, all = true) {
            if (pending) {
                clearTimeout(pending.timeout);
                pending.reject(failure(pending.element));
                pending = null;
            }
            const state = current;
            if (!state) return;
            suppressTransitionsForPresentation(state);
            current = null;
            if (state.child) send(state.child, 'leave');
            restore(state);
            if (!all) {
                while (stack.length) {
                    const previous = stack.pop();
                    if (previous.element.isConnected) {
                        present(previous.element, previous.child, previous.video);
                        return;
                    }
                }
            }
            stack.length = 0;
            notify(state.element, state.video);
            if (upward && window !== window.top) send(window.parent, 'exited');
        }
        function present(element, child = null, video = null) {
            if (current && current.element === element && current.child === child) return;
            // Read before changing presentation styles to avoid a forced style flush.
            // A nested replacement still needs the previous presentation restored first.
            const initialBackground = current ? null : getComputedStyle(element).backgroundColor;
            if (current) {
                const previous = current;
                suppressTransitionsForPresentation(previous);
                current = null;
                if (previous.child && previous.child !== child) send(previous.child, 'leave');
                restore(previous);
                stack.push({element: previous.element, child: previous.child, video: previous.video});
            }
            const state = {element, child, video, styles: [], styleAttributes: new Map(), observer: new MutationObserver(() => {
                if (!element.isConnected) leave();
            })};
            for (let target = element; target; target = ancestor(target)) {
                const transition = transitionStates.get(target);
                state.styleAttributes.set(target, transition ? transition.styleAttributes.get(target) : target.hasAttribute('style'));
            }
            const background = initialBackground ?? getComputedStyle(element).backgroundColor;
            suppressTransitionsForPresentation(state);
            const transparentBackground = background === 'transparent' || /^rgba\([^,]+,[^,]+,[^,]+,\s*0(?:\.0+)?\s*\)$/.test(background) || /\/\s*0(?:\.0+)?\s*\)$/.test(background);
            current = state;
            // Retain DOM ancestry, listeners, framework identity, and playing media.
            for (let parent = ancestor(element); parent; parent = ancestor(parent)) {
                const root = parent.getRootNode();
                if (root instanceof ShadowRoot) state.observer.observe(root, {childList: true, subtree: true});
                changeStyle(state, parent, {
                    transform: 'none', translate: 'none', rotate: 'none', scale: 'none',
                    filter: 'none', perspective: 'none', contain: 'none',
                    'content-visibility': 'visible', 'will-change': 'auto',
                    'overflow-x': 'visible', 'overflow-y': 'visible', 'clip-path': 'none', clip: 'auto',
                    opacity: '1', visibility: 'hidden', 'z-index': '2147483647'
                });
            }
            changeStyle(state, element, {
                position: 'fixed', top: '0px', right: '0px', bottom: '0px', left: '0px',
                width: '100vw', height: '100vh', 'min-width': '0px', 'min-height': '0px',
                'max-width': 'none', 'max-height': 'none',
                'margin-top': '0px', 'margin-right': '0px', 'margin-bottom': '0px', 'margin-left': '0px',
                'box-sizing': 'border-box', transform: 'none', translate: 'none', rotate: 'none', scale: 'none',
                'z-index': '2147483647', visibility: 'visible', opacity: '1',
                'content-visibility': 'visible'
            });
            if (transparentBackground) changeStyle(state, element, {'background-color': 'black'});
            if (element.localName === 'iframe' || element.localName === 'frame') {
                changeStyle(state, element, {
                    'border-top-width': '0px', 'border-right-width': '0px', 'border-bottom-width': '0px', 'border-left-width': '0px',
                    'padding-top': '0px', 'padding-right': '0px', 'padding-bottom': '0px', 'padding-left': '0px'
                });
            }
            if (document.documentElement !== element) changeStyle(state, document.documentElement, {'overflow-x': 'hidden', 'overflow-y': 'hidden'});
            state.observer.observe(document, {childList: true, subtree: true});
            const root = element.getRootNode();
            if (root instanceof ShadowRoot) state.observer.observe(root, {childList: true, subtree: true});
            notify(element, video);
        }
        function enter(element, child = null, video = null) {
            if (!(element instanceof Element) || !element.isConnected || element.ownerDocument !== document || element.localName === 'dialog' || !permitted() || !activated()) {
                return Promise.reject(failure(element));
            }
            if (pending) return Promise.reject(failure(element));
            if (window === window.top) {
                present(element, child, video);
                return Promise.resolve();
            }
            return new Promise((resolve, reject) => {
                const id = ++serial;
                // A bounded protocol deadline handles a parent frame without the injected script.
                const timeout = setTimeout(() => {
                    if (!pending || pending.id !== id) return;
                    pending = null;
                    send(window.parent, 'exited');
                    reject(failure(element));
                }, 1000);
                pending = {id, element, child, video, resolve, reject, timeout};
                send(window.parent, 'enter', {id});
            });
        }
        function findFrame(source, root = document) {
            for (const frame of root.querySelectorAll('iframe, frame')) {
                if (frame.contentWindow === source) return frame;
            }
            // Search shadow roots only in response to a child-frame request.
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
            while (walker.nextNode()) {
                if (walker.currentNode.shadowRoot) {
                    const frame = findFrame(source, walker.currentNode.shadowRoot);
                    if (frame) return frame;
                }
            }
            return null;
        }
        function framePermitted(frame, origin) {
            const policy = frame.permissionsPolicy || frame.featurePolicy;
            if (policy && typeof policy.allowsFeature === 'function') return policy.allowsFeature('fullscreen');
            const directive = (frame.getAttribute('allow') || '').split(';').map(value => value.trim()).find(value => /^fullscreen(?:\s|$)/i.test(value));
            if (directive) {
                const values = directive.split(/\s+/).slice(1);
                if (values.includes("'none'")) return false;
                if (!values.length || values.includes('*')) return true;
                if (values.includes("'self'") && origin === location.origin) return true;
                let sourceOrigin = '';
                try { sourceOrigin = new URL(frame.src, document.baseURI).origin; } catch (_) {}
                return values.includes(origin) || (values.includes("'src'") && origin === sourceOrigin);
            }
            return frame.hasAttribute('allowfullscreen') || frame.hasAttribute('webkitallowfullscreen') || (origin !== 'null' && origin === location.origin);
        }
        window.addEventListener('message', event => {
            const data = event.data;
            if (!data || data.channel !== channel) return;
            if (event.source === window.parent && window !== window.top) {
                if (data.action === 'leave') { leave(false); return; }
                if (data.action === 'entered' && !pending && !current) { send(window.parent, 'exited'); return; }
                if ((data.action === 'entered' || data.action === 'denied') && pending && pending.id === data.id) {
                    const request = pending;
                    pending = null;
                    clearTimeout(request.timeout);
                    if (data.action === 'denied' || !request.element.isConnected) {
                        if (data.action === 'entered') send(window.parent, 'exited');
                        request.reject(failure(request.element));
                    }
                    else { present(request.element, request.child, request.video); request.resolve(); }
                    return;
                }
            }
            if (data.action === 'exited' && current && current.child === event.source) { leave(); return; }
            if (data.action !== 'enter') return;
            const frame = findFrame(event.source);
            if (!frame || !framePermitted(frame, event.origin)) {
                if (frame) send(event.source, 'denied', {id: data.id});
                return;
            }
            enter(frame, event.source).then(
                () => send(event.source, 'entered', {id: data.id}),
                () => send(event.source, 'denied', {id: data.id})
            );
        });
        function define(target, name, descriptor) {
            const previous = Object.getOwnPropertyDescriptor(target, name);
            if (!previous || previous.configurable) Object.defineProperty(target, name, {configurable: true, enumerable: previous ? previous.enumerable : true, ...descriptor});
        }
        function retarget(root) {
            let element = current && current.element;
            while (element && element.getRootNode() !== root) {
                const tree = element.getRootNode();
                element = tree instanceof ShadowRoot ? tree.host : null;
            }
            return element;
        }
        for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
            define(Element.prototype, name, {writable: true, value: function() { return enter(this); }});
        }
        for (const name of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen']) {
            const originalExit = Document.prototype[name];
            define(Document.prototype, name, {writable: true, value: function() {
                if (this !== document || !current) {
                    if (originalExit) return originalExit.call(this);
                    return Promise.reject(new TypeError());
                }
                leave(true, false); return Promise.resolve();
            }});
        }
        for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']) {
            const originalDocumentElement = Object.getOwnPropertyDescriptor(Document.prototype, name);
            const originalShadowElement = Object.getOwnPropertyDescriptor(ShadowRoot.prototype, name);
            define(Document.prototype, name, {get() {
                if (current && this === document) return retarget(document);
                return originalDocumentElement && originalDocumentElement.get ? originalDocumentElement.get.call(this) : null;
            }});
            define(ShadowRoot.prototype, name, {get() {
                if (current) return retarget(this);
                return originalShadowElement && originalShadowElement.get ? originalShadowElement.get.call(this) : null;
            }});
        }
        for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled']) {
            define(Document.prototype, name, {get() { return this === document && permitted(); }});
        }
        const originalIsFullscreen = Object.getOwnPropertyDescriptor(Document.prototype, 'webkitIsFullScreen');
        define(Document.prototype, 'webkitIsFullScreen', {get() {
            return (this === document && !!current) || !!(originalIsFullscreen && originalIsFullscreen.get && originalIsFullscreen.get.call(this));
        }});
        for (const name of ['webkitEnterFullscreen', 'webkitEnterFullScreen']) {
            define(HTMLVideoElement.prototype, name, {writable: true, value: function() {
                if (!activated() || !permitted() || !this.isConnected) throw new DOMException('', 'InvalidStateError');
                enter(this, null, this).catch(() => {});
            }});
        }
        for (const name of ['webkitExitFullscreen', 'webkitExitFullScreen']) {
            const originalExit = HTMLVideoElement.prototype[name];
            define(HTMLVideoElement.prototype, name, {writable: true, value: function() {
                if (current && current.element === this) leave();
                else if (originalExit) return originalExit.call(this);
            }});
        }
        define(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', {get() {
            return !!(current && current.element === this) || !!(originalVideoFullscreen && originalVideoFullscreen.get && originalVideoFullscreen.get.call(this));
        }});
        define(HTMLVideoElement.prototype, 'webkitPresentationMode', {get() {
            return current && current.element === this ? 'fullscreen' : originalVideoMode && originalVideoMode.get ? originalVideoMode.get.call(this) : 'inline';
        }});
        define(HTMLVideoElement.prototype, 'webkitSetPresentationMode', {writable: true, value: function(mode) {
            if (mode === 'fullscreen') { this.webkitEnterFullscreen(); return; }
            if ((mode === 'inline' || mode === 'picture-in-picture') && current && current.element === this) leave();
            if (originalSetVideoMode) return originalSetVideoMode.call(this, mode);
        }});
        window.addEventListener('keydown', event => {
            if (event.key === 'Escape' && (current || pending)) {
                event.preventDefault(); event.stopImmediatePropagation(); leave();
            }
        }, true);
        window.addEventListener('pagehide', () => { leave(); clearTransitionSuppression(); });
        Object.defineProperty(window, '__cmuxContainedFullscreen', {
            value: Object.freeze({
                exit() { leave(); return Promise.resolve(); },
                bindNativeDocument(token) {
                    if (window !== window.top || typeof token !== 'string') return;
                    documentID = token;
                    report();
                }
            }), configurable: false
        });
    })();
    """#
}
