when defined(linux):
  {.passC: "-I" & staticExec("pwd") & "/webview".}
  {.passC: "-DWEBVIEW_GTK=1" &
          staticExec"pkg-config --cflags gtk+-3.0 webkit2gtk-4.0".}
  {.passL: staticExec"pkg-config --libs gtk+-3.0 webkit2gtk-4.0".}
elif defined(windows):
  {.passC: "-I." & staticExec("cmd /c cd").}
  {.passC: "-DWEBVIEW_WINAPI=1".}
  {.passL: "-lole32 -lcomctl32 -loleaut32 -luuid -mwindows".}
elif defined(darwin):
  {.passC: "-I" & staticExec("pwd") & "/webview".}
  {.passC: "-DWEBVIEW_COCOA=1 -x objective-c".}
  {.passL: "-framework Cocoa -framework WebKit".}

include webview/private/api

import tables, strutils
import macros

##
## Hight level api and javascript bindings to easy bidirectonal 
## message passsing for ``nim`` and the ``webview`` .
##

# proc binding support
import json

type
  # ExternalProc[P, R] = proc(param: P, ret: var R): int
  CallHook = proc(params: string): string # json -> proc -> json
  MethodInfo* = object
    name: string
    args: string # json string

# for bindProc
var eps = newTable[Webview, TableRef[string, CallHook]]()

# easy callbacks
var cbs = newTable[Webview, ExternalInvokeCb]()

proc generalExternalInvokeCallback(w: Webview, arg: cstring) {.exportc.} =
  var handled = false
  if eps.hasKey(w):
    try:
      var mi = parseJson($arg).to(MethodInfo)
      if hasKey(eps[w], mi.name):
        discard eps[w][mi.name](mi.args) # TODO handle return values using js callbacks
        handled = true
    except:
      echo getCurrentExceptionMsg()
  elif cbs.hasKey(w): 
    cbs[w](w, $arg)
    handled = true
  if handled == false:
    echo "external invode:'", arg, "' not handled"

proc `externalInvokeCB=`*(w: Webview, cb: ExternalInvokeCb)=
  ## Set external invoke callback for webview
  cbs[w] = cb

proc newWebView*(title="WebView", url="", 
                 width=640, height=480, 
                 resizable=true, debug=false,
                 cb:ExternalInvokeCb=nil): Webview =
  ## ``newWebView`` creates and opens a new webview window using the given settings. 
  ## This function will do webview ``init``
  var w = cast[Webview](alloc0(sizeof(WebviewObj)))
  w.title = title
  w.url = url
  w.width = width.cint
  w.height = height.cint
  w.resizable = if resizable: 1 else: 0
  w.debug = if debug: 1 else: 0
  w.invokeCb = generalExternalInvokeCallback
  if cb != nil:
    w.externalInvokeCB=cb
  if w.init() != 0: return nil
  return w

proc dialog*(w :Webview, dlgType: DialogType, flags: int, title, arg: string): string =
  ## dialog() opens a system dialog of the given type and title. String
  ## argument can be provided for certain dialogs, such as alert boxes. For
  ## alert boxes argument is a message inside the dialog box.
  let maxPath = 4096
  let resultPtr = cast[cstring](alloc0(maxPath))
  defer: dealloc(resultPtr)
  w.dialog(dlgType, flags.cint, title.cstring, arg.cstring, resultPtr, maxPath.csize) 
  return $resultPtr

proc alert*(w: Webview, title, msg: string) =
  ## Show one alert box
  discard w.dialog(dtAlert, 0, title, msg)

proc dialogOpen*(w: Webview, title="Open File", flag=dFlagFile): string =
  ## Opens a dialog that requests filenames from the user. Returns ""
  ## if the user closed the dialog without selecting a file. 
  return w.dialog(dtOpen, flag, title, "")

proc dialogSave*(w: Webview, title="Save File", flag=dFlagFile): string =
  ## Opens a dialog that requests a filename to save to from the user.
  ## Returns "" if the user closed the dialog without selecting a file.
  return w.dialog(dtSave, flag, title, "")

proc run*(w: Webview)=
  ## ``run`` starts the main UI loop until the user closes the webview window or
  ## Terminate() is called.
  while w.loop(1) == 0:
    discard

proc open*(title="WebView", url="", width=640, height=480, resizable=true):int {.discardable.} =
  ## Open is a simplified API to open a single native window with a full-size webview in
  ## it. It can be helpful if you want to communicate with the core app using XHR
  ## or WebSockets (as opposed to using JavaScript bindings).
  ##
  ## Window appearance can be customized using title, width, height and resizable parameters.
  ## URL must be provided and can user either a http or https protocol, or be a
  ## local file:// URL. On some platforms "data:" URLs are also supported
  ## (Linux/MacOS).
  webview(title.cstring, url.cstring, width.cint, height.cint, (if resizable: 1 else: 0).cint)

const
  jsTemplate = """
if (typeof api === 'undefined') {
	api = {};
}
api.$1 = function(arg) {
	window.external.invoke(
    JSON.stringify(
      {name: "$1", args: JSON.stringify(arg)}
    )
  );
};
"""
  jsTemplateOnlyArg = """
if (typeof api === 'undefined') {
	api = {};
}
api.$1 = function(arg) {
	window.external.invoke(
    JSON.stringify(
      {name: "$1", args: JSON.stringify(arg)}
    )
  );
};
"""
  jsTemplateNoArg = """
if (typeof api === 'undefined') {
	api = {};
}
api.$1 = function() {
	window.external.invoke(
    JSON.stringify(
      {name: "$1", args: ""}
    )
  );
};
"""

proc bindProc*[P, R](w: Webview, name: string, p: (proc(param: P): R)) =
  proc hook(hookParam: string): string =
    var 
      paramVal: P
      retVal: R
    try:
      let jnode = parseJson(hookParam)
      echo jnode
      paramVal = jnode.to(P)
    except:
      return "parse args failed: " & getCurrentExceptionMsg()
    retVal = p(paramVal)
    return $(%*retVal) # ==> json
  discard eps.hasKeyOrPut(w, newTable[string, CallHook]())
  eps[w][name] = hook
  # TODO eval jscode
  discard w.eval(jsTemplate%[name])

proc bindProc*(w: Webview, name: string, p: proc()) =
  proc hook(hookParam: string): string =
    p()
    return ""
  discard eps.hasKeyOrPut(w, newTable[string, CallHook]())
  eps[w][name] = hook
  # TODO eval jscode
  discard w.eval(jsTemplateNoArg%[name])

proc bindProc*[P](w: Webview, name: string, p: proc(arg:P)) =
  proc hook(hookParam: string): string =
    var 
      paramVal: P
    try:
      let jnode = parseJson(hookParam)
      paramVal = jnode.to(P)
    except:
      return "parse args failed: " & getCurrentExceptionMsg()
    p(paramVal)
    return ""
  discard eps.hasKeyOrPut(w, newTable[string, CallHook]())
  eps[w][name] = hook
  # TODO eval jscode
  discard w.eval(jsTemplateOnlyArg%[name])

macro bindProc*(w: Webview, n: untyped): untyped =
  ## proc can have many args but only one return types
  ## and no pragmas
  expectKind(n, nnkStmtList)
  result = n
  var nProc = 0
  for def in n:
    expectKind(def, nnkProcDef)
    let params = def.params()
    # expectKind(params[0], nnkSym)
    if params.len() > 2 :
      error("only proc like `proc fn[T, U](arg: T): U` or `proc fn[T](arg: T)` or `proc()` is allowed", 
            def)
    let fname = $def[0]
    result.add(newCall("bindProc", w, newLit(fname), newIdentNode(fname)))
  echo treeRepr result

proc call(w: WebView, mi: MethodInfo):string =
  let hook = eps[w][mi.name]
  return hook(mi.args)

proc callEPS*(w: Webview, fn, args: string): string =
  let mi = MethodInfo(name:fn, args:args)
  return w.call(mi)


