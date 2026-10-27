// wml-runtime.js — RetroNavigator
//
// A small WML user agent that runs inside the HTML generated from a WML deck
// (see WAPRenderer.swift). It shows one card at a time and implements WML
// variables, timers, events, <do> softkeys, <go>/<prev>/<refresh>/<noop>
// tasks and WMLScript (translated to JavaScript and run with the standard
// WMLScript libraries).

(function () {
    "use strict";

    const deck = window.WML_DECK;
    const cardsElement = document.getElementById("wml-cards");
    const titleElement = document.getElementById("wml-title");
    const softkeysElement = document.getElementById("wml-softkeys");

    /** WMLScript's `invalid` value. */
    const INVALID = Object.freeze({ toString() { return "invalid"; } });

    // MARK: Variables

    // WML variables live in the browser context, across decks. window.name
    // survives navigations (even across hosts) for the lifetime of the window.
    const VARIABLES_PREFIX = "wml-vars:";
    let variables = {};
    try {
        if (window.name.startsWith(VARIABLES_PREFIX)) {
            variables = JSON.parse(window.name.slice(VARIABLES_PREFIX.length)) || {};
        }
    } catch (error) {
        variables = {};
    }

    function saveVariables() {
        window.name = VARIABLES_PREFIX + JSON.stringify(variables);
    }

    function hasVariable(name) {
        return Object.prototype.hasOwnProperty.call(variables, name);
    }

    function getVariable(name) {
        return hasVariable(name) ? variables[name] : "";
    }

    function setVariable(name, value) {
        if (!name) return;
        variables[name] = String(value);
        saveVariables();
    }

    /**
     * Replaces $(name), $(name:conversion) and $name references. In URL
     * contexts variables are escaped unless :noesc or :unesc is given.
     */
    function substitute(text, isURLContext) {
        if (!text || text.indexOf("$") < 0) return text || "";
        const pattern = /\$\$|\$\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*([A-Za-z]+))?\s*\)|\$([A-Za-z_][A-Za-z0-9_]*)/g;
        return text.replace(pattern, (match, bracketedName, conversion, plainName) => {
            if (match === "$$") return "$";
            const value = getVariable(bracketedName || plainName);
            const mode = (conversion || (isURLContext ? "escape" : "noesc")).toLowerCase();
            if (mode === "escape" || mode === "e") return encodeURIComponent(value);
            if (mode === "unesc" || mode === "u") {
                try { return decodeURIComponent(value); } catch (error) { return value; }
            }
            return value;
        });
    }

    // MARK: Cards

    let currentCardId = null;
    const cardHistory = [];
    let timerHandle = null;

    function sectionFor(id) {
        return cardsElement.querySelector(`section.wml-card[data-card="${CSS.escape(id)}"]`);
    }

    function showCard(id, direction) {
        if (!deck.cards[id]) id = deck.order[0];
        if (!id) return;
        clearTimer();

        if (direction !== "backward" || cardHistory.length === 0) {
            cardHistory.push(id);
        }
        currentCardId = id;
        const card = deck.cards[id];
        if (card.newcontext) {
            variables = {};
            saveVariables();
        }

        for (const section of cardsElement.querySelectorAll("section.wml-card")) {
            section.hidden = section.dataset.card !== id;
        }
        cardsElement.scrollTop = 0;
        renderCard(id);

        // onenterforward / onenterbackward run their task on entry.
        const eventName = direction === "backward" ? "onenterbackward" : "onenterforward";
        const action = card.events[eventName] || deck.template.events[eventName];
        if (action) {
            execute(action);
            if (action.type === "go" || action.type === "prev") return;
        }
        startTimer(card);
    }

    function renderCard(id) {
        const card = deck.cards[id];
        const section = sectionFor(id);
        const title = substitute(card.title || deck.title || "");
        titleElement.textContent = title;
        if (title) document.title = title;

        section.querySelectorAll("[data-template]").forEach((element) => {
            element.textContent = substitute(element.dataset.template);
        });
        section.querySelectorAll("a[data-action]").forEach((link) => {
            const action = JSON.parse(link.dataset.action);
            link.href = action.type === "go" ? resolveURL(substitute(action.href, true)) : "#";
        });
        section.querySelectorAll("input[data-name]").forEach((input) => {
            const name = input.dataset.name;
            if (hasVariable(name)) {
                input.value = getVariable(name);
            } else {
                input.value = substitute(input.dataset.default || "");
                if (input.value) setVariable(name, input.value);
            }
        });
        section.querySelectorAll("select[data-name], select[data-iname]").forEach(initializeSelect);
        renderSoftkeys(card);
    }

    function initializeSelect(select) {
        const name = select.dataset.name;
        const indexName = select.dataset.iname;
        const options = Array.from(select.options);
        let selectedValues = null;
        if (indexName && hasVariable(indexName)) {
            const indexes = getVariable(indexName).split(";").map((value) => parseInt(value, 10) - 1);
            options.forEach((option, index) => { option.selected = indexes.includes(index); });
        } else {
            const raw = name && hasVariable(name) ? getVariable(name) : substitute(select.dataset.default || "");
            selectedValues = raw ? raw.split(";") : null;
            if (selectedValues) {
                options.forEach((option) => { option.selected = selectedValues.includes(option.value); });
            }
        }
        storeSelection(select);
    }

    function storeSelection(select) {
        const selected = Array.from(select.options).filter((option) => option.selected);
        if (select.dataset.name) {
            setVariable(select.dataset.name, selected.map((option) => option.value).join(";"));
        }
        if (select.dataset.iname) {
            const indexes = selected.map((option) => option.index + 1);
            setVariable(select.dataset.iname, indexes.join(";"));
        }
    }

    function renderSoftkeys(card) {
        // Card-level <do> elements override template ones with the same name.
        const softkeys = new Map();
        for (const item of deck.template.dos) softkeys.set(item.name, item);
        for (const item of card.dos) softkeys.set(item.name, item);
        const list = Array.from(softkeys.values()).filter((item) => item.action && item.action.type !== "noop");
        if (!list.some((item) => item.action.type === "prev") && (cardHistory.length > 1 || history.length > 1)) {
            list.push({ type: "prev", label: "Back", action: { type: "prev" } });
        }

        softkeysElement.textContent = "";
        for (const item of list) {
            const button = document.createElement("button");
            button.type = "button";
            button.textContent = substitute(item.label) || defaultLabel(item.type);
            button.addEventListener("click", () => execute(item.action));
            softkeysElement.appendChild(button);
        }
    }

    function defaultLabel(type) {
        return { accept: "OK", prev: "Back", options: "Options", help: "Help", reset: "Clear", delete: "Delete" }[type] || "OK";
    }

    // MARK: Timers

    function startTimer(card) {
        const timer = card.timer;
        if (!timer) return;
        let value = timer.value;
        if (timer.name) {
            if (hasVariable(timer.name)) value = getVariable(timer.name);
            else setVariable(timer.name, value);
        }
        const tenths = parseInt(value, 10);
        const action = card.events.ontimer || deck.template.events.ontimer;
        if (!(tenths > 0) || !action) return;
        timerHandle = setTimeout(() => {
            timerHandle = null;
            if (timer.name) setVariable(timer.name, "0");
            execute(action);
        }, tenths * 100);
    }

    function clearTimer() {
        if (timerHandle) clearTimeout(timerHandle);
        timerHandle = null;
    }

    // MARK: Tasks

    function execute(action) {
        if (!action) return;
        switch (action.type) {
            case "go": {
                // The href is substituted before the task's <setvar>s are applied.
                const href = substitute(action.href || "", true);
                applySetvars(action.setvars);
                go(href, action);
                break;
            }
            case "prev":
                applySetvars(action.setvars);
                previous();
                break;
            case "refresh":
                applySetvars(action.setvars);
                refresh();
                break;
            default:
                break;
        }
    }

    function applySetvars(setvars) {
        for (const [name, value] of setvars || []) {
            setVariable(substitute(name), substitute(value));
        }
    }

    function refresh() {
        if (!currentCardId) return;
        clearTimer();
        renderCard(currentCardId);
        startTimer(deck.cards[currentCardId]);
    }

    function previous() {
        if (cardHistory.length > 1) {
            cardHistory.pop();
            showCard(cardHistory[cardHistory.length - 1], "backward");
        } else {
            history.back();
        }
    }

    function resolveURL(href) {
        try { return new URL(href, deck.url).href; } catch (error) { return href; }
    }

    function withoutFragment(href) {
        const index = href.indexOf("#");
        return index < 0 ? href : href.slice(0, index);
    }

    function go(href, action) {
        if (!href) return;
        if (href.startsWith("#")) {
            showCard(decodeURIComponent(href.slice(1)), "forward");
            return;
        }
        let url;
        try { url = new URL(href, deck.url); } catch (error) { return; }

        if (/\.wmlsc?$/i.test(url.pathname)) {
            runScript(url);
            return;
        }
        if (url.hash && withoutFragment(url.href) === withoutFragment(deck.url) && deck.cards[decodeURIComponent(url.hash.slice(1))]) {
            showCard(decodeURIComponent(url.hash.slice(1)), "forward");
            return;
        }

        const fields = (action && action.postfields || []).map(([name, value]) => [substitute(name), substitute(value)]);
        if (action && (action.method || "get").toLowerCase() === "post") {
            const form = document.createElement("form");
            form.method = "post";
            form.action = url.href;
            form.acceptCharset = "utf-8";
            for (const [name, value] of fields) {
                const input = document.createElement("input");
                input.type = "hidden";
                input.name = name;
                input.value = value;
                form.appendChild(input);
            }
            document.body.appendChild(form);
            form.submit();
        } else {
            for (const [name, value] of fields) url.searchParams.append(name, value);
            window.location.href = url.href;
        }
    }

    // MARK: Events from the page

    cardsElement.addEventListener("click", (event) => {
        const element = event.target.closest("[data-action]");
        if (!element || element.tagName === "OPTION" || element.tagName === "SELECT") return;
        event.preventDefault();
        execute(JSON.parse(element.dataset.action));
    });

    cardsElement.addEventListener("input", (event) => {
        const input = event.target;
        if (input.matches("input[data-name]")) setVariable(input.dataset.name, input.value);
    });

    cardsElement.addEventListener("change", (event) => {
        const select = event.target;
        if (!select.matches("select")) return;
        storeSelection(select);
        const option = select.options[select.selectedIndex];
        if (option && option.dataset.onpick) execute(JSON.parse(option.dataset.onpick));
    });

    // MARK: WMLScript

    class ScriptExit {
        constructor(value) { this.value = value; }
    }

    let pendingNavigation = null;
    let scriptBaseURL = deck.url;

    const isInvalid = (value) => value === INVALID || value === undefined || value === null ||
        (typeof value === "number" && !isFinite(value));
    const toText = (value) => (isInvalid(value) ? "" : String(value));
    const separatorOf = (separator) => toText(separator).charAt(0);
    const clampIndex = (index, length) => Math.min(Math.max(Math.trunc(index), 0), Math.max(length - 1, 0));

    const LangLibrary = {
        abs: (value) => Math.abs(value),
        min: (a, b) => Math.min(a, b),
        max: (a, b) => Math.max(a, b),
        parseInt: (text) => { const value = parseInt(toText(text), 10); return isNaN(value) ? INVALID : value; },
        parseFloat: (text) => { const value = parseFloat(toText(text)); return isNaN(value) ? INVALID : value; },
        isInt: (text) => !isNaN(parseInt(toText(text), 10)),
        isFloat: (text) => !isNaN(parseFloat(toText(text))),
        maxInt: () => 2147483647,
        minInt: () => -2147483648,
        float: () => true,
        exit: (value) => { throw new ScriptExit(value); },
        abort: (message) => { throw new ScriptExit(message); },
        random: (limit) => (limit >= 0 ? Math.floor(Math.random() * (Math.trunc(limit) + 1)) : INVALID),
        seed: () => "",
        characterSet: () => 106 // UTF-8 (IANA MIBenum)
    };

    const FloatLibrary = {
        int: (value) => Math.trunc(value),
        floor: (value) => Math.floor(value),
        ceil: (value) => Math.ceil(value),
        pow: (base, exponent) => Math.pow(base, exponent),
        round: (value) => Math.round(value),
        sqrt: (value) => (value < 0 ? INVALID : Math.sqrt(value)),
        maxFloat: () => 3.40282347e38,
        minFloat: () => 1.17549435e-38
    };

    const StringLibrary = {
        length: (text) => toText(text).length,
        isEmpty: (text) => toText(text).length === 0,
        charAt: (text, index) => toText(text).charAt(index),
        subString: (text, start, length) => toText(text).substr(Math.max(0, start), length),
        find: (text, part) => toText(text).indexOf(toText(part)),
        replace: (text, oldPart, newPart) => toText(text).split(toText(oldPart)).join(toText(newPart)),
        elements: (text, separator) => toText(text).split(separatorOf(separator)).length,
        elementAt: (text, index, separator) => {
            const parts = toText(text).split(separatorOf(separator));
            return parts[clampIndex(index, parts.length)];
        },
        removeAt: (text, index, separator) => {
            const character = separatorOf(separator);
            const parts = toText(text).split(character);
            parts.splice(clampIndex(index, parts.length), 1);
            return parts.join(character);
        },
        replaceAt: (text, value, index, separator) => {
            const character = separatorOf(separator);
            const parts = toText(text).split(character);
            parts[clampIndex(index, parts.length)] = toText(value);
            return parts.join(character);
        },
        insertAt: (text, value, index, separator) => {
            const character = separatorOf(separator);
            const parts = toText(text).split(character);
            parts.splice(Math.min(Math.max(Math.trunc(index), 0), parts.length), 0, toText(value));
            return parts.join(character);
        },
        squeeze: (text) => toText(text).replace(/\s+/g, " "),
        trim: (text) => toText(text).trim(),
        compare: (a, b) => { a = toText(a); b = toText(b); return a < b ? -1 : (a > b ? 1 : 0); },
        toString: (value) => (isInvalid(value) ? "invalid" : String(value)),
        format: (format, value) => toText(format).replace(/%(-?\d*)(?:\.(\d+))?([dfs%])/, (match, width, precision, type) => {
            if (type === "%") return "%";
            let text;
            if (type === "d") text = String(Math.trunc(Number(value)));
            else if (type === "f") text = Number(value).toFixed(precision ? Number(precision) : 6);
            else text = precision ? toText(value).slice(0, Number(precision)) : toText(value);
            const size = Math.abs(parseInt(width || "0", 10));
            return width.startsWith("-") ? text.padEnd(size) : text.padStart(size);
        })
    };

    const parseURL = (value) => { try { return new URL(toText(value), deck.url); } catch (error) { return null; } };
    const URLLibrary = {
        isValid: (value) => parseURL(value) !== null,
        getScheme: (value) => { const url = parseURL(value); return url ? url.protocol.slice(0, -1) : INVALID; },
        getHost: (value) => { const url = parseURL(value); return url ? url.hostname : INVALID; },
        getPort: (value) => { const url = parseURL(value); return url ? url.port : INVALID; },
        getPath: (value) => { const url = parseURL(value); return url ? url.pathname : INVALID; },
        getParameters: (value) => {
            const url = parseURL(value);
            if (!url) return INVALID;
            const index = url.pathname.lastIndexOf(";");
            return index < 0 ? "" : url.pathname.slice(index + 1);
        },
        getQuery: (value) => { const url = parseURL(value); return url ? url.search.slice(1) : INVALID; },
        getFragment: (value) => { const url = parseURL(value); return url ? url.hash.slice(1) : INVALID; },
        getBase: () => scriptBaseURL,
        getReferer: () => deck.url,
        resolve: (base, embedded) => { try { return new URL(toText(embedded), toText(base)).href; } catch (error) { return INVALID; } },
        escapeString: (text) => encodeURIComponent(toText(text)),
        unescapeString: (text) => { try { return decodeURIComponent(toText(text)); } catch (error) { return INVALID; } },
        loadString: (url) => {
            // WMLScript is synchronous, so this uses a synchronous request.
            try {
                const request = new XMLHttpRequest();
                request.open("GET", new URL(toText(url), scriptBaseURL).href, false);
                request.send();
                return request.status >= 200 && request.status < 300 ? request.responseText : request.status;
            } catch (error) {
                return INVALID;
            }
        }
    };

    // Navigation requested by a script happens after the script finishes.
    const WMLBrowserLibrary = {
        getVar: (name) => getVariable(toText(name)),
        setVar: (name, value) => { setVariable(toText(name), toText(value)); return true; },
        go: (url) => { pendingNavigation = { type: "go", href: toText(url) }; return ""; },
        prev: () => { pendingNavigation = { type: "prev" }; return ""; },
        refresh: () => { pendingNavigation = { type: "refresh" }; return ""; },
        newContext: () => { variables = {}; saveVariables(); cardHistory.length = 0; return ""; },
        getCurrentCard: () => (currentCardId ? "#" + currentCardId : INVALID)
    };

    const DialogsLibrary = {
        alert: (message) => { window.alert(toText(message)); return ""; },
        confirm: (message) => window.confirm(toText(message)),
        prompt: (message, defaultInput) => {
            const result = window.prompt(toText(message), toText(defaultInput));
            return result === null ? toText(defaultInput) : result;
        }
    };

    /** WMLScript's `div`: integer division, invalid when dividing by zero. */
    const integerDivide = (a, b) => (Number(b) === 0 || isInvalid(a) || isInvalid(b) ? INVALID : Math.trunc(Number(a) / Number(b)));

    /** Calls to functions in other script units aren't supported. */
    const externalFunction = () => () => INVALID;

    /** Splits WMLScript call arguments like `'a', 2, true` into values. */
    function parseArguments(text) {
        const values = [];
        const pattern = /\s*('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|[^,]+)\s*(?:,|$)/g;
        let match;
        while ((match = pattern.exec(text)) && match[0] !== "") {
            const token = match[1].trim();
            if (/^['"]/.test(token)) values.push(token.slice(1, -1).replace(/\\(.)/g, "$1"));
            else if (token === "true" || token === "false") values.push(token === "true");
            else if (token === "invalid") values.push(INVALID);
            else if (token !== "" && !isNaN(Number(token))) values.push(Number(token));
            else values.push(token);
        }
        return values;
    }

    /**
     * Translates WMLScript source to JavaScript. The syntax is close to
     * JavaScript; the differences are rewritten token by token.
     */
    function translateWMLScript(source) {
        const tokens = [];
        const numberPattern = /0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/y;
        let index = 0;
        while (index < source.length) {
            const character = source[index];
            const next = source[index + 1];
            if (character === "/" && next === "/") {
                const end = source.indexOf("\n", index);
                index = end < 0 ? source.length : end;
            } else if (character === "/" && next === "*") {
                const end = source.indexOf("*/", index + 2);
                index = end < 0 ? source.length : end + 2;
                tokens.push({ type: "space", text: " " });
            } else if (/\s/.test(character)) {
                let end = index;
                while (end < source.length && /\s/.test(source[end])) end++;
                tokens.push({ type: "space", text: source.slice(index, end) });
                index = end;
            } else if (character === "'" || character === "\"") {
                let end = index + 1;
                while (end < source.length && source[end] !== character) {
                    if (source[end] === "\\") end++;
                    end++;
                }
                tokens.push({ type: "string", text: source.slice(index, end + 1) });
                index = end + 1;
            } else if (/[A-Za-z_]/.test(character)) {
                let end = index;
                while (end < source.length && /\w/.test(source[end])) end++;
                tokens.push({ type: "identifier", text: source.slice(index, end) });
                index = end;
            } else if (/[0-9.]/.test(character) && (numberPattern.lastIndex = index, numberPattern.test(source))) {
                tokens.push({ type: "number", text: source.slice(index, numberPattern.lastIndex) });
                index = numberPattern.lastIndex;
            } else {
                tokens.push({ type: "punctuation", text: character });
                index++;
            }
        }

        const nextToken = (from) => {
            let position = from + 1;
            while (position < tokens.length && tokens[position].type === "space") position++;
            return position;
        };
        const previousToken = (from) => {
            let position = from - 1;
            while (position >= 0 && tokens[position].type === "space") position--;
            return position;
        };

        // Integer division: rewrite `a div b` to `__div(a, b)`. Operands are
        // identifiers, numbers or literals with member access, calls and
        // parenthesized groups.
        const matching = { ")": "(", "]": "[" };
        const operandStart = (end) => {
            let position = end;
            for (;;) {
                const token = tokens[position];
                if (!token) return position + 1;
                if (matching[token.text]) {
                    let depth = 0;
                    for (; position >= 0; position--) {
                        if (tokens[position].text === token.text) depth++;
                        else if (tokens[position].text === matching[token.text] && --depth === 0) break;
                    }
                    const before = previousToken(position);
                    if (before >= 0 && (tokens[before].type === "identifier" || matching[tokens[before].text])) {
                        position = before;
                        continue;
                    }
                    return position;
                }
                const before = previousToken(position);
                if (before >= 0 && tokens[before].text === ".") {
                    position = previousToken(before);
                    continue;
                }
                return position;
            }
        };
        const operandEnd = (start) => {
            let position = start;
            if (tokens[position] && (tokens[position].text === "-" || tokens[position].text === "+")) position = nextToken(position);
            for (;;) {
                const token = tokens[position];
                if (!token) return position - 1;
                if (token.text === "(" || token.text === "[") {
                    const close = token.text === "(" ? ")" : "]";
                    let depth = 0;
                    for (; position < tokens.length; position++) {
                        if (tokens[position].text === token.text) depth++;
                        else if (tokens[position].text === close && --depth === 0) break;
                    }
                }
                const after = nextToken(position);
                if (tokens[after] && (tokens[after].text === "." || tokens[after].text === "(" || tokens[after].text === "[")) {
                    position = tokens[after].text === "." ? nextToken(after) : after;
                    continue;
                }
                return position;
            }
        };
        for (let position = 0; position < tokens.length; position++) {
            const token = tokens[position];
            if (token.type !== "identifier" || token.text !== "div") continue;
            const after = nextToken(position);
            if (tokens[after] && tokens[after].text === "=") continue; // `div=` stays as `/=`
            const leftEnd = previousToken(position);
            const leftStart = operandStart(leftEnd);
            const rightEnd = operandEnd(after);
            const text = (from, to) => tokens.slice(from, to + 1).map((item) => item.text).join("");
            const replacement = { type: "code", text: `__div(${text(leftStart, leftEnd)}, ${text(after, rightEnd)})` };
            tokens.splice(leftStart, rightEnd - leftStart + 1, replacement);
            position = leftStart;
        }

        const output = [];
        for (let position = 0; position < tokens.length; position++) {
            const token = tokens[position];
            if (token.type === "identifier") {
                switch (token.text) {
                    case "extern":
                        continue;
                    case "use":
                        // Pragmas: use url / use access / use meta … ;
                        while (position < tokens.length && tokens[position].text !== ";") position++;
                        continue;
                    case "div":
                        // Only `div=` is left at this point.
                        output.push("/");
                        continue;
                    case "isvalid":
                        output.push("__invalid !== ");
                        continue;
                    case "invalid":
                        output.push("__invalid");
                        continue;
                    default: {
                        // Calls into other script units: Alias#function(…)
                        const hash = nextToken(position);
                        if (tokens[hash] && tokens[hash].text === "#") {
                            const name = nextToken(hash);
                            output.push(`__external(${JSON.stringify(token.text)}, ${JSON.stringify(tokens[name] ? tokens[name].text : "")})`);
                            position = name;
                            continue;
                        }
                    }
                }
            }
            output.push(token.text);
        }
        return output.join("");
    }

    async function runScript(url) {
        const call = decodeURIComponent(url.hash.slice(1));
        url.hash = "";
        const match = /^\s*([A-Za-z_]\w*)\s*\(([\s\S]*)\)\s*$/.exec(call);
        if (!match) {
            window.alert("WMLScript: invalid function call \"" + call + "\".");
            return;
        }
        if (/\.wmlsc$/i.test(url.pathname)) {
            window.alert("Compiled WMLScript (.wmlsc) isn't supported.");
            return;
        }

        let source;
        try {
            const response = await fetch(url.href);
            source = await response.text();
        } catch (error) {
            window.alert("WMLScript: could not load " + url.href);
            return;
        }

        pendingNavigation = null;
        scriptBaseURL = url.href;
        const functionName = match[1];
        try {
            const body = translateWMLScript(source) +
                `\nreturn (typeof ${functionName} === "function") ? ${functionName}.apply(null, __arguments) : __invalid;`;
            const run = new Function("Lang", "Float", "String", "URL", "WMLBrowser", "Dialogs",
                "__invalid", "__external", "__div", "__arguments", body);
            run(LangLibrary, FloatLibrary, StringLibrary, URLLibrary, WMLBrowserLibrary, DialogsLibrary,
                INVALID, externalFunction, integerDivide, parseArguments(match[2]));
        } catch (error) {
            if (!(error instanceof ScriptExit)) {
                console.error(error);
                window.alert("WMLScript error: " + error.message);
            }
        }

        const navigation = pendingNavigation;
        pendingNavigation = null;
        if (navigation) execute(navigation);
        else refresh();
    }

    // MARK: Start

    if (!deck.order.length) {
        titleElement.textContent = "WML";
        cardsElement.textContent = "This WML deck has no cards.";
        return;
    }
    const navigationEntry = performance.getEntriesByType("navigation")[0];
    const startCard = decodeURIComponent((window.location.hash || "").slice(1));
    showCard(deck.cards[startCard] ? startCard : deck.order[0],
        navigationEntry && navigationEntry.type === "back_forward" ? "backward" : "forward");
})();
