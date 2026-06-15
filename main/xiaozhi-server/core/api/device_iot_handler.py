"""设备 IoT 命令管理接口

POST /xiaozhi/device/{mac}/iot-command
Body: {"name": "Speaker", "method": "SetVolume", "parameters": {"volume": 80}}
"""

import json
from aiohttp import web
from core.api.base_handler import BaseHandler
from core import connection_registry

TAG = __name__


class DeviceIoTHandler(BaseHandler):
    def __init__(self, config: dict):
        super().__init__(config)
        self._api_secret = config.get("server", {}).get("management_api_secret", "")

    async def handle_iot_command(self, request: web.Request) -> web.Response:
        # 可选鉴权：配置了 management_api_secret 时才校验
        if self._api_secret:
            auth = request.headers.get("Authorization", "")
            token = auth.removeprefix("Bearer ").strip()
            if token != self._api_secret:
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

        self.logger.bind(tag=TAG).info(f"IoT 命令已下发 mac={mac} {name}.{method} params={parameters}")
        return web.json_response({"success": True})

    async def handle_online_devices(self, request: web.Request) -> web.Response:
        return web.json_response({"devices": connection_registry.online_devices()})

    async def handle_device_state(self, request: web.Request) -> web.Response:
        """GET /xiaozhi/device/{mac}/state — 单设备当前 IoT 属性值"""
        mac = request.match_info["mac"]
        handler = connection_registry.get(mac)
        if handler is None:
            return web.json_response({"success": False, "error": "设备离线"}, status=404)

        state = self._extract_state(handler)
        return web.json_response({"success": True, "state": state})

    async def handle_online_states(self, request: web.Request) -> web.Response:
        """GET /xiaozhi/device/online-states — 所有在线设备的状态批量返回"""
        result = {}
        for mac in connection_registry.online_devices():
            handler = connection_registry.get(mac)
            if handler is not None:
                result[mac] = self._extract_state(handler)
        return web.json_response({"success": True, "devices": result})

    @staticmethod
    def _extract_state(handler) -> dict:
        """从 ConnectionHandler.iot_descriptors 提取属性名→值的扁平字典"""
        state = {}
        for component_name, descriptor in handler.iot_descriptors.items():
            state[component_name] = {p["name"]: p["value"] for p in descriptor.properties}
        return state
