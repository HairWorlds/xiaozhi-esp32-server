"""全局设备连接注册表，维护 device_id → ConnectionHandler 的活跃映射"""

from typing import TYPE_CHECKING, Dict, Optional

if TYPE_CHECKING:
    from core.connection import ConnectionHandler

# device_id (MAC 地址) → ConnectionHandler
_registry: Dict[str, "ConnectionHandler"] = {}


def register(device_id: str, handler: "ConnectionHandler") -> None:
    if device_id:
        _registry[device_id] = handler


def unregister(device_id: str) -> None:
    _registry.pop(device_id, None)


def get(device_id: str) -> Optional["ConnectionHandler"]:
    return _registry.get(device_id)


def online_devices() -> list:
    return list(_registry.keys())
