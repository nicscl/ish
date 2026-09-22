hterm.defaultStorage = new lib.Storage.Memory();
window.onload = async function() {
    await lib.init();
    window.term = new hterm.Terminal();

    // make everything invisible so as to not be embarrassing
    term.getPrefs().set('background-color', 'transparent');
    term.getPrefs().set('foreground-color', 'transparent');
    term.getPrefs().set('cursor-color', 'transparent');

    term.getPrefs().set('terminal-encoding', 'iso-2022');
    term.getPrefs().set('enable-resize-status', false);
    term.getPrefs().set('copy-on-select', false);
    term.getPrefs().set('enable-clipboard-notice', false);
    term.getPrefs().set('user-css-text', termCss);
    term.getPrefs().set('screen-padding-size', 4);
    // Creating and preloading the <audio> element for this sometimes hangs WebKit on iOS 16 for some reason. Can be most easily reproduced by resetting a simulator and starting the app. System logs show Fig hanging while trying to do work.
    term.getPrefs().set('audible-bell-sound', '');

    term.onTerminalReady = onTerminalReady;
    term.decorate(document.getElementById('terminal'));
};

var termCss = `
x-screen {
    background: transparent !important;
    overflow: hidden !important;
    -webkit-tap-highlight-color: transparent;
}
x-row {
  text-rendering: optimizeLegibility;
  font-variant-ligatures: normal;
}
.uri-node {
  text-decoration: underline;
}
`;

function onTerminalReady() {

// Shorthand for JS -> native IPC
// Presentation handlers (focus, scrolling, links) are only registered while a
// TerminalView is showing this terminal, so a message with no handler is dropped
// rather than thrown: a hidden terminal must keep processing output.
const native = new Proxy({}, {
    get(obj, prop) {
        return (...args) => {
            if (args.length == 0)
                args = null;
            else if (args.length == 1)
                args = args[0];
            const handler = webkit.messageHandlers[prop];
            if (handler !== undefined)
                handler.postMessage(args);
        };
    },
});
window.addEventListener('error', (e) => native.log('term.js error: ' + e.message + ' at ' + e.filename + ':' + e.lineno));

// Functions for native -> JS
window.exports = {};

term.io.push();
term.reset();

let oldProps = {};
function syncProp(name, value) {
    if (oldProps[name] !== value)
        native.propUpdate(name, value);
}
let decoder = new TextDecoder();
exports.write = (data) => {
    term.io.writeUTF16(decoder.decode(lib.codec.stringToCodeUnitArray(data)));
    syncProp('applicationCursor', term.keyboard.applicationCursor);
};
term.io.sendString = term.io.onVTKeyStroke = (data) => {
    native.sendInput(data);
};

// hterm size updates native size
term.io.onTerminalResize = () => native.resize();
exports.getSize = () => [term.screenSize.width, term.screenSize.height];

// selection, copying
term.scrollPort_.screen_.contentEditable = false;
term.blur();
term.focus();
exports.copy = () => term.copySelectionToClipboard();

// focus
// This listener blocks blur events that come in because the webview has lost first responder
term.scrollPort_.screen_.addEventListener('blur', (e) => {
    if (e.target.ownerDocument.activeElement == e.target) {
        e.stopPropagation();
    }
}, {capture: true});
term.scrollPort_.screen_.addEventListener('mousedown', (e) => {
    // Taps while there is a selection should be left to the selection view
    if ((document.getSelection().rangeCount != 0) &&
        (!document.getSelection().isCollapsed)) return;
    native.focus();
});
exports.setFocused = (focus) => {
    if (focus)
        term.focus();
    else
        term.blur();
};
term.scrollPort_.screen_.addEventListener('focus', (e) => native.syncFocus());

// scrolling
// Disable hterm builtin touch scrolling
term.scrollPort_.onTouch = (e) => {
    // Convince hterm that we called preventDefault() and that it shouldn't do more handling, but don't actually call it because that would break text selection
    Object.defineProperty(e, 'defaultPrevented', {value: true});
};
// Scroll to bottom wrapper
exports.scrollToBottom = () => term.scrollEnd();
// Set scroll position
exports.newScrollTop = (y) => {
    // two lines instead of one because the value you read out of scrollTop can be different from the value you write into it
    term.scrollPort_.screen_.scrollTop = y;
    lastScrollTop = term.scrollPort_.screen_.scrollTop;
};

// Send scroll height and position to native code
let lastScrollHeight, lastScrollTop;
function syncScroll() {
    const scrollHeight = parseFloat(term.scrollPort_.scrollArea_.style.height);
    if (scrollHeight != lastScrollHeight)
        native.newScrollHeight(scrollHeight);
    lastScrollHeight = scrollHeight;

    const scrollTop = term.scrollPort_.screen_.scrollTop;
    if (scrollTop != lastScrollTop)
        native.newScrollTop(scrollTop);
    lastScrollTop = scrollTop;
}

// Called by native code when a TerminalView (re)attaches, since scroll updates
// sent while detached were dropped.
exports.resyncScroll = () => {
    lastScrollHeight = lastScrollTop = undefined;
    syncScroll();
};

const realSyncScrollHeight = hterm.ScrollPort.prototype.syncScrollHeight;
hterm.ScrollPort.prototype.syncScrollHeight = function() {
    realSyncScrollHeight.call(this);
    syncScroll();
};
term.scrollPort_.screen_.addEventListener('scroll', syncScroll);

exports.updateStyle = ({foregroundColor, backgroundColor, fontFamily, fontSize, colorPaletteOverrides, blinkCursor, cursorShape}) => {
    term.getPrefs().set('background-color', backgroundColor);
    term.getPrefs().set('foreground-color', foregroundColor);
    term.getPrefs().set('cursor-color', foregroundColor);
    term.getPrefs().set('font-family', fontFamily);
    term.getPrefs().set('font-size', fontSize);
    term.getPrefs().set('color-palette-overrides', colorPaletteOverrides);
    term.getPrefs().set('cursor-blink', blinkCursor);
    term.getPrefs().set('cursor-shape', cursorShape);
};

exports.getCharacterSize = () => {
    return [term.scrollPort_.characterSize.width, term.scrollPort_.characterSize.height];
};

exports.clearScrollback = () => term.clearScrollback();
exports.clearScreen = () => term.wipeContents();
exports.reset = () => term.reset();
exports.getText = () => term.getRowsText(0, term.getRowCount());
exports.setUserGesture = () => term.accessibilityReader_.hasUserGesture = true;

// A Cmd-click can reach both hterm's own link handling and openLinkAt, so drop
// a repeat of the same URL.
let lastOpened, lastOpenedTime = 0;
hterm.openUrl = (url) => {
    const now = Date.now();
    if (url === lastOpened && now - lastOpenedTime < 1000)
        return;
    lastOpened = url;
    lastOpenedTime = now;
    native.openLink(url);
};

// Opens the link at a point in the web view, for Cmd-click. Links written with
// OSC 8 carry their URL; otherwise the URL is found in the text, following it
// across rows the terminal wrapped.
const urlPattern = /(?:[a-zA-Z][a-zA-Z0-9+.-]*:\/\/|mailto:|www\.)[^\s<>"'`]+/g;
exports.openLinkAt = (x, y) => {
    const frame = term.scrollPort_.iframe_.getBoundingClientRect();
    const doc = term.document_;
    x -= frame.left;
    y -= frame.top;
    const node = doc.elementFromPoint(x, y);
    const uriNode = node && node.closest('.uri-node');
    if (uriNode) {
        hterm.openUrl(uriNode.title);
        return;
    }
    const row = node && node.closest('x-row');
    const caret = doc.caretRangeFromPoint(x, y);
    if (!row || !caret || !row.contains(caret.startContainer))
        return;

    // Offset of the click within the row's text.
    let offset = 0;
    const walker = doc.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    for (let text; (text = walker.nextNode()) && text !== caret.startContainer;)
        offset += text.length;
    offset += caret.startOffset;

    // Join the row with the rows it wraps from and into.
    let first = row, last = row;
    while (first.previousElementSibling && first.previousElementSibling.hasAttribute('line-overflow'))
        first = first.previousElementSibling;
    while (last.hasAttribute('line-overflow') && last.nextElementSibling)
        last = last.nextElementSibling;
    let line = '';
    for (let r = first; ; r = r.nextElementSibling) {
        if (r === row)
            offset += line.length;
        line += r.textContent;
        if (r === last)
            break;
    }

    for (const match of line.matchAll(urlPattern)) {
        const url = match[0].replace(/[.,;:!?)\]}]+$/, '');
        if (offset >= match.index && offset <= match.index + url.length) {
            hterm.openUrl(url.startsWith('www.') ? 'http://' + url : url);
            return;
        }
    }
};

native.load();
native.syncFocus();

}
