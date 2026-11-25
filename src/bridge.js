/*  bridge.js -- preload.js for the Windows version.

	The original's shell page (index.html, index.js, index.css) runs here
	unchanged, in WebView2. In Electron it reaches the app through
	window.mdBrowser, which preload.js makes; this file makes the same
	object. Each call goes to bonbon.exe as a message and its answer comes
	back as one.

	Three things the original's main process did in JavaScript are done
	here, in the page, with the original's own code, so they come out the
	same: the front matter (frontMatter.js, js-yaml), the Markdown
	(markdownConverter.js, marked 3.0.8) and the page handlers
	(pageHandlers.js: a worker in a box with no way out, here a sandboxed
	frame nobody sees). bonbon.exe puts marked and js-yaml where the two
	markers are.  */

(function () {
	if ((window !== window.top) || (location.origin !== "http://bonbon.example") || (window.chrome === undefined) || (window.chrome.webview === undefined)) { //the shell's alone: a page that took its place gets no bridge (bonbon.exe checks too)
		return;
		}
	const webview = window.chrome.webview;

	/*  CTRL-CLICK. The shell opens a link in a new tab on a Cmd-click, the
		Mac's key; it asks event.metaKey, which on Windows is the Windows key.
		Here Ctrl counts as Cmd for a mouse event, the way Windows browsers do
		it, so index.js stays as it is.  */

	const metaKeyOfMouse = Object.getOwnPropertyDescriptor (MouseEvent.prototype, "metaKey");
	Object.defineProperty (MouseEvent.prototype, "metaKey", {
		configurable: true,
		enumerable: metaKeyOfMouse.enumerable,
		get: function () {
			return (metaKeyOfMouse.get.call (this) || this.ctrlKey);
			}
		});

	const marked = (function () {
		var module = {exports: {}}, exports = module.exports, define = undefined;
		/*MARKED*/
		return (module.exports);
		}) ();
	const yaml = (function () {
		var module = {exports: {}}, exports = module.exports, define = undefined;
		/*JSYAML*/
		return (module.exports);
		}) ();

	/*  THE MESSAGES. A call is {id, name, args}; its answer is {id, result},
		and result isn't there when the answer is undefined. A menu command
		is {command, param}.  */

	var idLastCall = 0;
	const callsWaiting = {};
	var commandCallback, commandsWaiting = [];
	webview.addEventListener ("message", function (event) {
		const theMessage = event.data;
		if (theMessage.command !== undefined) {
			if (commandCallback === undefined) {
				commandsWaiting.push (theMessage);
				}
			else {
				commandCallback (theMessage.command, theMessage.param);
				}
			return;
			}
		const resolve = callsWaiting [theMessage.id];
		delete callsWaiting [theMessage.id];
		if (resolve !== undefined) {
			resolve (theMessage.result);
			}
		});
	function invoke (theName, ...theArgs) {
		return (new Promise (function (resolve) {
			const id = ++idLastCall;
			callsWaiting [id] = resolve;
			webview.postMessage ({id, name: theName, args: theArgs});
			}));
		}
	window.addEventListener ("load", function () { //Electron's did-finish-load: a bon:// link that came early can open now
		webview.postMessage ({name: "loaded", args: []});
		});
	window.close = function () { //closing the last tab closes the app; Chromium lets a page close only a window a script opened, Electron lets its window go
		webview.postMessage ({name: "closeWindow", args: []});
		};

	/*  frontMatter.js  */

	function splitFrontMatter (theText) { //answers {frontMatter, markdown}
		var frontMatter = {}, markdown = theText;
		const theLines = theText.split ("\n");
		if (theLines [0].trim () === "---") {
			var ixEnd = -1, i;
			for (i = 1; i < theLines.length; i++) {
				const theLine = theLines [i].trim ();
				if ((theLine === "---") || (theLine === "...")) {
					ixEnd = i;
					break;
					}
				}
			if (ixEnd !== -1) {
				const yamlText = theLines.slice (1, ixEnd).join ("\n");
				try {
					const jstruct = yaml.load (yamlText);
					if ((jstruct !== null) && (typeof jstruct === "object")) {
						frontMatter = jstruct;
						}
					}
				catch (err) {
					console.log ("Can't read the front matter because " + err.message);
					}
				markdown = theLines.slice (ixEnd + 1).join ("\n");
				}
			}
		return ({frontMatter, markdown});
		}

	/*  markdownConverter.js  */

	function convertMarkdownToHtml (theMarkdown) {
		const theRenderer = new marked.Renderer ();
		theRenderer.html = function (theHtml) {
			return ("");
			};
		return (marked (theMarkdown, {renderer: theRenderer}));
		}

	/*  pageHandlers.js. bonbon.exe found the handler and read its files; it
		runs here. The box: a frame with an origin of its own and nobody's
		cookies (sandbox), a content security policy that allows no
		connections, which the worker started from it lives under too, and
		a worker, which can't navigate or make links. The frame's script and
		the worker's tail are the original's runInWorker.  */

	function runInWorker (theCode, options, ctSecsTimeout) { //answers a promise for {message} when the handler failed, {data} when it answered
		return (new Promise (function (resolve) {
			const theTail = "\n;self.onmessage = function (theEvent) {\n" +
				"\tfunction answer (theAnswer) {\n" +
				"\t\ttry {\n" +
				"\t\t\tself.postMessage (theAnswer);\n" +
				"\t\t\t}\n" +
				"\t\tcatch (err) {\n" +
				"\t\t\tself.postMessage ({message: \"what it sent back can't be passed along: \" + err.message});\n" +
				"\t\t\t}\n" +
				"\t\t}\n" +
				"\tif (typeof handler !== \"function\") {\n" +
				"\t\tanswer ({message: \"handler.js has no function named handler\"});\n" +
				"\t\treturn;\n" +
				"\t\t}\n" +
				"\ttry {\n" +
				"\t\thandler (theEvent.data, function (err, data) {\n" +
				"\t\t\tif (err) {\n" +
				"\t\t\t\tanswer ({message: \"it said: \" + ((err.message === undefined) ? String (err) : String (err.message))});\n" +
				"\t\t\t\t}\n" +
				"\t\t\telse {\n" +
				"\t\t\t\tanswer ({data});\n" +
				"\t\t\t\t}\n" +
				"\t\t\t});\n" +
				"\t\t}\n" +
				"\tcatch (err) {\n" +
				"\t\tanswer ({message: \"it stopped with an error: \" + err.message});\n" +
				"\t\t}\n" +
				"\t};\n";
			const urlWorker = URL.createObjectURL (new Blob ([theCode + theTail], {type: "text/javascript"}));
			var theWorker, theTimer, flDone = false;
			function done (theAnswer) {
				if (!flDone) {
					flDone = true;
					clearTimeout (theTimer);
					if (theWorker !== undefined) {
						theWorker.terminate ();
						}
					URL.revokeObjectURL (urlWorker);
					resolve (theAnswer);
					}
				}
			try {
				theWorker = new Worker (urlWorker);
				}
			catch (err) {
				done ({message: "it couldn't be started: " + err.message});
				return;
				}
			theWorker.onmessage = function (theEvent) {
				done (theEvent.data);
				};
			theWorker.onerror = function (theEvent) {
				theEvent.preventDefault ();
				done ({message: "handler.js has an error: " + theEvent.message + ((theEvent.lineno) ? " (line " + theEvent.lineno + ")" : "")});
				};
			theTimer = setTimeout (function () {
				done ({message: "it didn't answer in " + ctSecsTimeout + " seconds"});
				}, ctSecsTimeout * 1000);
			theWorker.postMessage (options);
			}));
		}
	const htmlHandlerFrame = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' blob:; worker-src blob:\"></head><body><script>" +
		"const runInWorker = " + runInWorker.toString () + ";\n" +
		"window.addEventListener (\"message\", function (event) {\n" +
		"\tconst theRun = event.data;\n" +
		"\trunInWorker (theRun.code, theRun.options, theRun.ctSecsTimeout).then (function (theAnswer) {\n" +
		"\t\ttry {\n" +
		"\t\t\tparent.postMessage ({idRun: theRun.idRun, answer: theAnswer}, \"*\");\n" +
		"\t\t\t}\n" +
		"\t\tcatch (err) {\n" +
		"\t\t\tparent.postMessage ({idRun: theRun.idRun, answer: {message: \"what it sent back can't be passed along: \" + err.message}}, \"*\");\n" +
		"\t\t\t}\n" +
		"\t\t});\n" +
		"\t});\n" +
		"</" + "script></body></html>";
	var handlerFrame, whenHandlerFrameReady, idLastRun = 0;
	const runsWaiting = {};
	window.addEventListener ("message", function (event) {
		if ((handlerFrame !== undefined) && (event.source === handlerFrame.contentWindow) && (event.data !== null) && (typeof event.data === "object")) {
			const resolve = runsWaiting [event.data.idRun];
			delete runsWaiting [event.data.idRun];
			if (resolve !== undefined) {
				resolve (event.data.answer);
				}
			}
		});
	function getHandlerFrame () { //made the first time a handler runs, kept after that; answers a promise for it
		if (handlerFrame === undefined) {
			handlerFrame = document.createElement ("iframe");
			handlerFrame.setAttribute ("sandbox", "allow-scripts");
			handlerFrame.style.display = "none";
			whenHandlerFrameReady = new Promise (function (resolve) {
				handlerFrame.addEventListener ("load", function () {
					resolve (handlerFrame);
					});
				});
			handlerFrame.srcdoc = htmlHandlerFrame;
			document.body.appendChild (handlerFrame);
			}
		return (whenHandlerFrameReady);
		}
	function closeHandlerFrame () {
		if (handlerFrame !== undefined) {
			handlerFrame.remove ();
			}
		handlerFrame = undefined;
		}
	function runHandler (theHandler, options, ctSecsTimeout, callback) { //callback (err, data); err.message is the reason, the part after "because"
		var flCalledBack = false, theBackstop;
		function finish (err, data) {
			if (!flCalledBack) {
				flCalledBack = true;
				clearTimeout (theBackstop);
				callback (err, data);
				}
			}
		theBackstop = setTimeout (function () { //the frame has its own timer; this one is for a frame that stopped answering altogether
			closeHandlerFrame ();
			finish ({message: "it didn't answer in " + ctSecsTimeout + " seconds"});
			}, (ctSecsTimeout + 2) * 1000);
		getHandlerFrame ().then (function (theFrame) {
			return (new Promise (function (resolve) {
				const idRun = ++idLastRun;
				runsWaiting [idRun] = resolve;
				theFrame.contentWindow.postMessage ({idRun, code: theHandler.code, options, ctSecsTimeout}, "*");
				}));
			}).then (function (theAnswer) {
				if ((theAnswer === undefined) || (theAnswer === null)) {
					finish ({message: "it didn't send anything back"});
					}
				else if (theAnswer.message !== undefined) {
					finish ({message: theAnswer.message});
					}
				else if ((theAnswer.data === undefined) || (theAnswer.data === null) || (typeof theAnswer.data.htmltext !== "string")) {
					finish ({message: "it didn't send back htmltext"});
					}
				else {
					finish (undefined, theAnswer.data);
					}
				}).catch (function (err) {
					finish ({message: "it couldn't be run: " + err.message});
					});
		}
	function handlePage (urlAsked, theResult, theHandler, callback) { //pageHandlers.js's handlePage; theHandler is {extension, code, config, configError, ctSecsTimeout, version}
		const theExtension = theHandler.extension;
		function failed (theReason) {
			theResult.handlerError = "Can't use the " + theExtension + " handler because " + theReason + ".";
			console.log (theResult.handlerError);
			callback (theResult);
			}
		if (theHandler.configError !== undefined) {
			failed (theHandler.configError);
			return;
			}
		const options = {
			pagetext: theResult.source,
			url: urlAsked,
			urlActual: theResult.url,
			contentType: theResult.contentType,
			extension: theExtension,
			headers: (theResult.headers === undefined) ? {} : theResult.headers,
			config: theHandler.config,
			version: theHandler.version
			};
		runHandler (theHandler, options, theHandler.ctSecsTimeout, function (err, data) {
			if (err) {
				failed (err.message);
				}
			else {
				callback ({
					flOk: true,
					kind: "handler",
					url: theResult.url,
					urlContentLocation: theResult.urlContentLocation,
					title: (typeof data.title === "string") ? data.title : undefined,
					htmltext: data.htmltext,
					source: theResult.source,
					extension: theExtension
					});
				}
			});
		}

	/*  preload.js  */

	function getPage (theUrl, flAsItCame) { //bonbon.exe answers the page as it came: flMarkdown when it's a Markdown page, handler when one wants it
		return (invoke ("getPage", theUrl, flAsItCame === true).then (function (theResult) {
			if (theResult.flMarkdown === true) {
				const thePage = splitFrontMatter (theResult.source);
				return ({flOk: true, url: theResult.url, urlContentLocation: theResult.urlContentLocation, frontMatter: thePage.frontMatter, html: convertMarkdownToHtml (thePage.markdown), source: theResult.source});
				}
			if (theResult.handler !== undefined) {
				const theHandler = theResult.handler;
				delete theResult.handler;
				return (new Promise (function (resolve) {
					handlePage (theUrl, theResult, theHandler, resolve);
					}));
				}
			return (theResult);
			}));
		}

	window.mdBrowser = {
		getConfig: function () {
			return (invoke ("getConfig"));
			},
		getVersion: function () {
			return (invoke ("getVersion"));
			},
		getToc: function (theUrl) {
			return (invoke ("getToc", theUrl));
			},
		isMarkdownUrl: function (theUrl) {
			return (invoke ("isMarkdownUrl", theUrl));
			},
		getUrlStatus: function (theUrl) {
			return (invoke ("getUrlStatus", theUrl));
			},
		toggleDevTools: function () {
			return (invoke ("toggleDevTools"));
			},
		openDataFolder: function () {
			return (invoke ("openDataFolder"));
			},
		openSourceWindow: function (theUrl, theSource) {
			return (invoke ("openSourceWindow", theUrl, theSource));
			},
		getStylesheets: function () {
			return (invoke ("getStylesheets"));
			},
		getUserCss: function () {
			return (invoke ("getUserCss"));
			},
		getTabs: function () {
			return (invoke ("getTabs"));
			},
		saveTabs: function (theState) {
			return (invoke ("saveTabs", theState));
			},
		onCommand: function (callback) {
			commandCallback = callback;
			const theCommands = commandsWaiting;
			commandsWaiting = [];
			theCommands.forEach (function (theMessage) {
				callback (theMessage.command, theMessage.param);
				});
			},
		getUrlHistory: function () {
			return (invoke ("getUrlHistory"));
			},
		saveUrlHistory: function (theList) {
			return (invoke ("saveUrlHistory", theList));
			},
		getHistory: function () {
			return (invoke ("getHistory"));
			},
		saveHistory: function (theList) {
			return (invoke ("saveHistory", theList));
			},
		getBookmarks: function () {
			return (invoke ("getBookmarks"));
			},
		saveBookmarks: function (opmltext, theOutline) {
			return (invoke ("saveBookmarks", opmltext, theOutline));
			},
		setBookmarksMenu: function (theOutline) {
			return (invoke ("setBookmarksMenu", theOutline));
			},
		showContextMenu: function (theParams) {
			return (invoke ("showContextMenu", theParams));
			},
		getFavicon: function (theUrl) {
			return (invoke ("getFavicon", theUrl));
			},
		getPage,
		openInBrowser: function (theUrl) {
			return (invoke ("openInBrowser", theUrl));
			}
		};
	Object.freeze (window.mdBrowser); //contextBridge's object can't be changed by the page either

	/*  NEW VERSIONS, the Windows version's own. A few seconds after the start
		the app asks GitHub for its latest release; when it's newer than this
		one and hasn't been offered before, the original's confirm dialog says
		so, and OK opens its page in the reader's browser. Each version is
		offered once. flCheckForUpdates false in config.json turns it off; no
		answer (offline, a private repo, GitHub's limit) means no word.  */

	const urlLatestRelease = "https://api.github.com/repos/Latz/BonBon-Windows/releases/latest";

	function isNewerVersion (a, b) { //"1.0.10" is newer than "1.0.9"
		const pa = a.split ("."), pb = b.split (".");
		for (var i = 0; i < Math.max (pa.length, pb.length); i++) {
			const x = parseInt (pa [i] || "0", 10) || 0, y = parseInt (pb [i] || "0", 10) || 0;
			if (x !== y) {
				return (x > y);
				}
			}
		return (false);
		}

	function checkForUpdates () {
		return (Promise.all ([invoke ("getConfig"), invoke ("getVersion")]).then (function ([config, version]) {
			if (config.flCheckForUpdates === false) {
				return;
				}
			return (fetch (urlLatestRelease).then (function (response) {
				return (response.ok ? response.json () : undefined);
				}).then (function (release) {
				if ((release === undefined) || (typeof release.tag_name !== "string")) {
					return;
					}
				const latest = release.tag_name.replace (/^v/, "");
				if (!isNewerVersion (latest, version) || (localStorage.getItem ("bonbonUpdateOffered") === latest)) {
					return;
					}
				localStorage.setItem ("bonbonUpdateOffered", latest);
				confirmDialog ("BonBon for Windows " + latest + " is available; this is " + version + ". Open its download page?", function () {
					invoke ("openInBrowser", release.html_url);
					});
				}));
			}).catch (function () {
			}));
		}
	Object.defineProperty (window, "bonbonCheckForUpdates", {value: checkForUpdates}); //for the tests
	window.addEventListener ("load", function () {
		setTimeout (checkForUpdates, 5000);
		});
	}) ();
