"""设备 IoT 命令管理接口

POST /xiaozhi/device/{mac}/iot-command
Body: {"name": "Speaker", "method": "SetVolume", "parameters": {"volume": 80}}

GET  /xiaozhi/device/online-states   — 所有在线设备状态（在线状态 + 实时音量等）
GET  /xiaozhi/device/{mac}/state     — 单设备状态
GET  /xiaozhi/device/online          — 在线设备 MAC 列表
"""

import asyncio
import json
from aiohttp import web
from core.api.base_handler import BaseHandler
from core import connection_registry

TAG = __name__

# MCP get_device_status 工具的 sanitized 名称（点号被替换为下划线）
_MCP_GET_STATUS_TOOL = "self_get_device_status"


class DeviceIoTHandler(BaseHandler):
    def __init__(self, config: dict):
        super().__init__(config)
        self._api_secret = config.get("server", {}).get("management_api_secret", "")

    # ── 鉴权 ──────────────────────────────────────────────────

    def _check_auth(self, request: web.Request) -> bool:
        if not self._api_secret:
            return True
        auth = request.headers.get("Authorization", "")
        return auth.removeprefix("Bearer ").strip() == self._api_secret

    # ── IoT 命令下发 ───────────────────────────────────────────

    async def handle_iot_command(self, request: web.Request) -> web.Response:
        if not self._check_auth(request):
            return web.json_response({"success": False, "error": "Unauthorized"}, status=401)

        mac = request.match_info["mac"]
        handler = connection_registry.get(mac)
        if handler is None:
            return web.json_response({"success": False, "error": "设备离线或未连接"}, status=404)

        try:
            body = await request.json()
        except Exception:
            return web.json_response({"success": False, "error": "请求体必须为 JSON"}, status=400)

        name = body.get("name")
        method = body.get("method")
        parameters = body.get("parameters", {})

        if not name or not method:
            return web.json_response({"success": False, "error": "缺少 name 或 method 字段"}, status=400)

        command = {"type": "iot", "commands": [{"name": name, "method": method}]}
        if parameters:
            command["commands"][0]["parameters"] = parameters

        try:
            await handler.websocket.send(json.dumps(command, ensure_ascii=False))
        except Exception as e:
            self.logger.bind(tag=TAG).error(f"发送 IoT 命令失败 mac={mac}: {e}")
            return web.json_response({"success": False, "error": f"发送失败: {e}"}, status=500)

        # 本地缓存成功下发的音量值，供 _extract_state 使用（MCP 设备无 iot_descriptors）
        if name == "Speaker" and method == "SetVolume" and "volume" in parameters:
            if not hasattr(handler, "_device_state_cache"):
                handler._device_state_cache = {}
            handler._device_state_cache.setdefault("Speaker", {})["volume"] = parameters["volume"]

        self.logger.bind(tag=TAG).info(f"IoT 命令已下发 mac={mac} {name}.{method} params={parameters}")
        return web.json_response({"success": True})

    # ── 在线设备列表 ───────────────────────────────────────────

    async def handle_online_devices(self, request: web.Request) -> web.Response:
        return web.json_response({"devices": connection_registry.online_devices()})

    # ── 单设备状态 ─────────────────────────────────────────────

    async def handle_device_state(self, request: web.Request) -> web.Response:
        mac = request.match_info["mac"]
        handler = connection_registry.get(mac)
        if handler is None:
            return web.json_response({"success": False, "error": "设备离线"}, status=404)

        state = await self._extract_state_async(handler)
        return web.json_response({"success": True, "state": state})

    # ── 批量在线状态 ────────────────────────────────────────────

    async def handle_online_states(self, request: web.Request) -> web.Response:
        online = connection_registry.online_devices()
        self.logger.bind(tag=TAG).info(f"[DeviceIoT] GET /online-states 被调用，注册表在线设备: {online}")
        result = {}
        for mac in online:
            handler = connection_registry.get(mac)
            if handler is not None:
                result[mac] = await self._extract_state_async(handler)
        self.logger.bind(tag=TAG).info(f"[DeviceIoT] online-states 返回: {list(result.keys())}")
        return web.json_response({"success": True, "devices": result})

    # ── 状态提取（MCP 优先 → 本地缓存 → IoT 描述符）─────────────

    async def _extract_state_async(self, handler) -> dict:
        mac = getattr(handler, "device_id", "unknown")

        # 1. MCP 设备：调 self.get_device_status 拿实时状态
        mcp = getattr(handler, "mcp_client", None)
        mcp_ready = (mcp is not None and await mcp.is_ready())
        has_tool = mcp_ready and mcp.has_tool(_MCP_GET_STATUS_TOOL)
        self.logger.bind(tag=TAG).info(
            f"[DeviceIoT] _extract_state mac={mac} mcp_ready={mcp_ready} has_tool={has_tool}"
        )

        if has_tool:
            try:
                from core.providers.tools.device_mcp.mcp_handler import call_mcp_tool
                raw = await asyncio.wait_for(
                    call_mcp_tool(handler, mcp, _MCP_GET_STATUS_TOOL, "{}"),
                    timeout=3.0,
                )
                self.logger.bind(tag=TAG).info(f"[DeviceIoT] MCP get_device_status raw mac={mac}: {raw}")
                if raw:
                    data = json.loads(raw) if isinstance(raw, str) else {}
                    state = _normalize_mcp_state(data)
                    self.logger.bind(tag=TAG).info(f"[DeviceIoT] MCP state normalized mac={mac}: {state}")
                    if state:
                        return state
            except Exception as e:
                self.logger.bind(tag=TAG).warning(f"[DeviceIoT] MCP get_device_status 失败 mac={mac}: {e}")

        # 2. 本地缓存（我们通过 handle_iot_command 下发过的音量）
        cache = getattr(handler, "_device_state_cache", None)
        self.logger.bind(tag=TAG).info(f"[DeviceIoT] _device_state_cache mac={mac}: {cache}")
        if cache:
            return dict(cache)

        # 3. 经典 IoT 描述符（非 MCP 设备）
        state = {}
        for component_name, descriptor in handler.iot_descriptors.items():
            state[component_name] = {p["name"]: p["value"] for p in descriptor.properties}
        self.logger.bind(tag=TAG).info(f"[DeviceIoT] iot_descriptors mac={mac}: {state}")
        return state


def _normalize_mcp_state(data: dict) -> dict:
    """将 MCP self.get_device_status 的响应转换为 IoT 描述符格式 {Speaker: {volume: N}}"""
    if not isinstance(data, dict):
        return {}
    # 已经是 IoT 描述符格式（Speaker / Screen 等 PascalCase 键）
    if any(k in data for k in ("Speaker", "Screen", "Battery", "Network")):
        return data
    # 常见 MCP 字段映射
    result = {}
    if "audio" in data:
        result["Speaker"] = data["audio"]
    if "screen" in data:
        result["Screen"] = data["screen"]
    if "battery" in data:
        result["Battery"] = data["battery"]
    if "network" in data:
        result["Network"] = data["network"]
    # 扁平格式：{volume: 75}
    if "volume" in data and "Speaker" not in result:
        result["Speaker"] = {"volume": data["volume"]}
    return result
