"""Python 使用相同会话消息；读线程独立处理取消和宿主回复，不阻塞业务线程。"""
import base64
import json
import queue
import runpy
import sys
import threading
from types import SimpleNamespace
from pathlib import Path

# 本地依赖沿用插件目录；不生成字节码，避免改变已确认的受管副本。
sys.path.insert(0, str(Path(sys.argv[1]).resolve().parent))
sys.dont_write_bytecode = True

output = sys.stdout
sys.stdout = sys.stderr
write_lock = threading.Lock()
state_lock = threading.Lock()
events = queue.Queue(maxsize=16)
tasks = {}
replies = {}
handlers = {}
lifecycle = {"enter": [], "exit": []}
active = True
latest_items = []
latest_snapshot = []
latest_text = ""
sequence = 0
event_context = threading.local()
expired_replies = set()


def send(message):
    data = json.dumps({"protocol": 1, **message}, ensure_ascii=False) + "\n"
    if len(data.encode("utf-8")) > 24 * 1024 * 1024:
        raise ValueError("插件消息超过 24MB。")
    with write_lock:
        output.write(data)
        output.flush()


def subscribe(event, callback):
    if not callable(callback):
        raise ValueError("监听器必须可调用。")
    if event in lifecycle:
        lifecycle[event].append(callback)
        return lambda: lifecycle[event].remove(callback) if callback in lifecycle[event] else None
    if event in handlers:
        raise ValueError("只能注册一个业务处理器。")
    handlers[event] = callback
    return lambda: handlers.pop(event, None) if handlers.get(event) is callback else None


def host_call(method, params=None):
    global sequence
    if not active:
        raise ValueError("插件会话已退出。")
    if not hasattr(event_context, "identity") or event_context.signal.is_set():
        raise ValueError("插件输入已取消。")
    with state_lock:
        sequence += 1
        identity = f"host-{sequence}"
        reply = {"event": threading.Event()}
        replies[identity] = reply
    try:
        send({"type": "call", "id": identity, "method": method, "parentID": event_context.identity, "params": params or {}})
        import time
        deadline = time.monotonic() + 60
        while not reply["event"].wait(0.05):
            if event_context.signal.is_set() or time.monotonic() >= deadline:
                with state_lock:
                    expired_replies.add(identity)
                send({"type": "hostCancel", "id": identity})
                raise ValueError("插件输入已取消。" if event_context.signal.is_set() else "宿主调用超时。")
        response = reply["message"]
        if "error" in response:
            raise ValueError(response["error"])
        return response.get("value")
    finally:
        with state_lock:
            replies.pop(identity, None)


leap = SimpleNamespace(
    onEnter=lambda callback: subscribe("enter", callback),
    onInputChange=lambda callback: subscribe("input", callback),
    onSelect=lambda callback: subscribe("select", callback),
    onInvoke=lambda callback: subscribe("invoke", callback),
    onExit=lambda callback: subscribe("exit", callback),
    outPlugin=lambda: host_call("outPlugin"),
    hideMainWindow=lambda: host_call("hideMainWindow"),
    showLoading=lambda: host_call("showLoading"),
    hideLoading=lambda: host_call("hideLoading"),
    log=lambda *values: print(*values, file=sys.stderr),
)


def single_host(method, field, value):
    if field == "image":
        if isinstance(value, (bytes, bytearray)):
            if not value or len(value) > 16 * 1024 * 1024:
                raise ValueError("图片必须为 1 字节至 16MB。")
            value = "data:application/octet-stream;base64," + base64.b64encode(value).decode("ascii")
        elif not isinstance(value, str) or not value:
            raise ValueError("图片必须为路径、Data URL 或 bytes。")
    elif field == "filePath" and method.endswith("File"):
        if not isinstance(value, (str, list)) or (isinstance(value, list) and (not value or any(not isinstance(path, str) or not path for path in value))):
            raise ValueError("文件路径必须为字符串或非空路径数组。")
    elif not isinstance(value, str):
        raise ValueError("参数必须为字符串。")
    return host_call(method, {field: value})


def notification(body, clickFeatureCode=None):
    if not isinstance(body, str) or not body or (clickFeatureCode is not None and not isinstance(clickFeatureCode, str)):
        raise ValueError("通知正文及命令 ID 必须为字符串。")
    return host_call("showNotification", {"body": body, **({"clickFeatureCode": clickFeatureCode} if clickFeatureCode is not None else {})})


def keyboard(key, *modifiers):
    if not isinstance(key, str) or not key or any(not isinstance(value, str) for value in modifiers):
        raise ValueError("按键和修饰键必须为字符串。")
    return host_call("simulateKeyboardTap", {"key": key, "modifiers": list(modifiers)})


def copyText(text):
    return single_host("copyText", "text", text)


def copyFile(filePath):
    return single_host("copyFile", "filePath", filePath)


def copyImage(image):
    return single_host("copyImage", "image", image)


def hideMainWindowPasteText(text):
    return single_host("hideMainWindowPasteText", "text", text)


def hideMainWindowPasteFile(filePath):
    return single_host("hideMainWindowPasteFile", "filePath", filePath)


def hideMainWindowPasteImage(image):
    return single_host("hideMainWindowPasteImage", "image", image)


def hideMainWindowTypeString(text):
    return single_host("hideMainWindowTypeString", "text", text)


def shellOpenPath(fullPath):
    return single_host("shellOpenPath", "fullPath", fullPath)


def shellTrashItem(fullPath):
    return single_host("shellTrashItem", "fullPath", fullPath)


def shellShowItemInFolder(fullPath):
    return single_host("shellShowItemInFolder", "fullPath", fullPath)


def shellOpenExternal(url):
    return single_host("shellOpenExternal", "url", url)


def getPath(name):
    return single_host("getPath", "name", name)


def getFileIcon(filePath):
    return single_host("getFileIcon", "filePath", filePath)


def getCopyedFiles():
    return host_call("getCopyedFiles")


def shellBeep():
    return host_call("shellBeep")


def getNativeId():
    return host_call("getNativeId")


def getAppName():
    return host_call("getAppName")


def getAppVersion():
    return host_call("getAppVersion")


def readCurrentFolderPath():
    return host_call("readCurrentFolderPath")


def readCurrentBrowserUrl():
    return host_call("readCurrentBrowserUrl")


def isDev():
    return host_call("isDev")


def isMacOS():
    return host_call("isMacOS")


def isWindows():
    return host_call("isWindows")


def isLinux():
    return host_call("isLinux")


leap.copyText = copyText
leap.copyFile = copyFile
leap.copyImage = copyImage
leap.hideMainWindowPasteText = hideMainWindowPasteText
leap.hideMainWindowPasteFile = hideMainWindowPasteFile
leap.hideMainWindowPasteImage = hideMainWindowPasteImage
leap.hideMainWindowTypeString = hideMainWindowTypeString
leap.shellOpenPath = shellOpenPath
leap.shellTrashItem = shellTrashItem
leap.shellShowItemInFolder = shellShowItemInFolder
leap.shellOpenExternal = shellOpenExternal
leap.getPath = getPath
leap.getFileIcon = getFileIcon
leap.getCopyedFiles = getCopyedFiles
leap.shellBeep = shellBeep
leap.getNativeId = getNativeId
leap.getAppName = getAppName
leap.getAppVersion = getAppVersion
leap.readCurrentFolderPath = readCurrentFolderPath
leap.readCurrentBrowserUrl = readCurrentBrowserUrl
leap.isDev = isDev
leap.isMacOS = isMacOS
leap.isWindows = isWindows
leap.isLinux = isLinux
leap.showNotification = notification
leap.simulateKeyboardTap = keyboard


def handle(message):
    global active, latest_items, latest_snapshot, latest_text
    identity = message["id"]
    method = message.get("method")
    params = message.get("params")
    signal = tasks[identity]
    event_context.identity = identity
    event_context.signal = signal
    live = True
    published = False
    try:
        if not isinstance(params, dict) or not isinstance(params.get("commandID"), str) or not isinstance(params.get("query"), str):
            raise ValueError("事件参数无效。")
        if not active and method != "exit":
            raise ValueError("会话已退出。")
        context = {"commandID": params["commandID"], "query": params["query"], "signal": signal}
        value = None
        if method == "enter":
            for callback in lifecycle["enter"]:
                callback(context)
        elif method == "exit":
            active = False
            for callback in lifecycle["exit"]:
                callback()
        elif method == "input":
            latest_text = params["query"]
            latest_items = []
            latest_snapshot = []

            def set_list(items, options=None):
                nonlocal published
                global latest_items, latest_snapshot
                if not live or not active or signal.is_set():
                    return
                if not isinstance(items, list) or len(items) > 100:
                    raise ValueError("列表最多 100 项。")
                if any(not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"]
                       or not isinstance(item.get("title"), str) or not item["title"]
                       or ("description" in item and not isinstance(item["description"], str))
                       or ("imagePath" in item and not isinstance(item["imagePath"], str)) for item in items):
                    raise ValueError("条目 ID 和标题必须是非空字符串。")
                if len({item["id"] for item in items}) != len(items):
                    raise ValueError("条目 ID 重复。")
                # 与 JS 保持一致：缓存协议字段副本，业务对象后续修改不能改变已发布条目。
                if options is not None and (not isinstance(options, dict)
                                           or ("title" in options and not isinstance(options["title"], str))):
                    raise ValueError("列表选项必须为对象，顶部标题必须为字符串。")
                entries = [{key: item[key] for key in ("id", "title", "description", "imagePath") if key in item} for item in items]
                snapshot = {"items": entries, "title": options["title"]} if options is not None and "title" in options else entries
                send({"type": "list", "id": identity, "value": snapshot})
                latest_items = entries
                latest_snapshot = snapshot
                published = True

            callback = handlers.get("input")
            if callback:
                callback({"commandID": params["commandID"], "text": params["query"], "setList": set_list, "signal": signal})
            if not published:
                set_list([])
            value = latest_snapshot
        elif method == "select":
            item = next((item for item in latest_items if item["id"] == params.get("itemID")), None)
            if item is None or params["query"] != latest_text:
                raise ValueError("所选条目已失效。")
            callback = handlers.get("select")
            if callback:
                value = callback({"commandID": params["commandID"], "text": params["query"], "item": dict(item), "signal": signal})
        elif method == "invoke":
            callback = handlers.get("invoke")
            if callback is None:
                raise ValueError("插件未注册动作处理器。")
            value = callback(context)
        else:
            raise ValueError("未知事件。")
        if method != "input" and value is not None and not isinstance(value, str):
            raise ValueError("动作反馈必须是字符串。")
        send({"type": "result", "id": identity, "value": value})
    except Exception as error:
        print(str(error), file=sys.stderr)
        send({"type": "result", "id": identity, "error": str(error)})
    finally:
        live = False
        with state_lock:
            tasks.pop(identity, None)


def worker():
    while True:
        handle(events.get())


runpy.run_path(sys.argv[1], init_globals={"leap": leap}, run_name="__main__")
threading.Thread(target=worker, daemon=True).start()
send({"type": "ready", "id": "ready", "value": None})
while True:
    line = sys.stdin.buffer.readline(24 * 1024 * 1024 + 1)
    if not line:
        break
    if len(line) > 24 * 1024 * 1024 or not line.endswith(b"\n"):
        raise ValueError("输入消息超过限制或缺少换行。")
    message = json.loads(line)
    if message.get("protocol") != 1 or not isinstance(message.get("id"), str):
        raise ValueError("协议无效。")
    identity = message["id"]
    if message["type"] == "event":
        with state_lock:
            tasks[identity] = threading.Event()
        events.put_nowait(message)
    elif message["type"] == "cancel":
        with state_lock:
            if identity in tasks:
                tasks[identity].set()
    elif message["type"] == "result":
        with state_lock:
            reply = replies.get(identity)
            if reply is None and identity in expired_replies:
                expired_replies.remove(identity)
                continue
            if reply is None:
                raise ValueError("宿主响应标识无效。")
            reply["message"] = message
            reply["event"].set()
    else:
        raise ValueError("未知消息。")
