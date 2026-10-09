"""Python 使用相同会话消息；读线程独立处理取消和宿主回复，不阻塞业务线程。"""
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
latest_text = ""
sequence = 0


def send(message):
    data = json.dumps({"protocol": 1, **message}, ensure_ascii=False) + "\n"
    if len(data.encode("utf-8")) > 1024 * 1024:
        raise ValueError("插件消息超过 1MB。")
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
    with state_lock:
        sequence += 1
        identity = f"host-{sequence}"
        reply = {"event": threading.Event()}
        replies[identity] = reply
    try:
        send({"type": "call", "id": identity, "method": method, "params": params or {}})
        if not reply["event"].wait(3):
            raise ValueError("宿主调用超时。")
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
    copyText=lambda text: host_call("copyText", {"text": text}),
    outPlugin=lambda: host_call("outPlugin"),
    hideMainWindow=lambda: host_call("hideMainWindow"),
    log=lambda *values: print(*values, file=sys.stderr),
)


def handle(message):
    global active, latest_items, latest_text
    identity = message["id"]
    method = message.get("method")
    params = message.get("params")
    signal = tasks[identity]
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

            def set_list(items):
                nonlocal published
                global latest_items
                if not live or not active or signal.is_set():
                    return
                if not isinstance(items, list) or len(items) > 100:
                    raise ValueError("列表最多 100 项。")
                if any(not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"]
                       or not isinstance(item.get("title"), str) or not item["title"]
                       or ("description" in item and not isinstance(item["description"], str)) for item in items):
                    raise ValueError("条目 ID 和标题必须是非空字符串。")
                if len({item["id"] for item in items}) != len(items):
                    raise ValueError("条目 ID 重复。")
                # 与 JS 保持一致：缓存协议字段副本，业务对象后续修改不能改变已发布条目。
                snapshot = [{key: item[key] for key in ("id", "title", "description") if key in item} for item in items]
                send({"type": "list", "id": identity, "value": snapshot})
                latest_items = snapshot
                published = True

            callback = handlers.get("input")
            if callback:
                callback({"commandID": params["commandID"], "text": params["query"], "setList": set_list, "signal": signal})
            if not published:
                set_list([])
            value = latest_items
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
    line = sys.stdin.buffer.readline(1024 * 1024 + 1)
    if not line:
        break
    if len(line) > 1024 * 1024 or not line.endswith(b"\n"):
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
            if reply is None:
                raise ValueError("宿主响应标识无效。")
            reply["message"] = message
            reply["event"].set()
    else:
        raise ValueError("未知消息。")
