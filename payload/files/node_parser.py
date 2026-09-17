#!/usr/bin/env python3
"""Convert one common proxy share URI (or Clash JSON object) to Clash JSON."""

import base64
import json
import sys
from urllib.parse import parse_qs, unquote, urlsplit


def fail(message):
    raise ValueError(message)


def decode_base64(value):
    compact = "".join(value.strip().split())
    compact += "=" * (-len(compact) % 4)
    try:
        return base64.urlsafe_b64decode(compact.encode("ascii")).decode("utf-8")
    except Exception:
        fail("分享链接中的 Base64 内容无效")


def as_port(value):
    try:
        port = int(value)
    except (TypeError, ValueError):
        fail("节点端口无效")
    if port < 1 or port > 65535:
        fail("节点端口必须在 1 到 65535 之间")
    return port


def as_bool(value):
    return str(value or "").lower() in ("1", "true", "yes", "on")


def clean_name(value, fallback):
    name = unquote(str(value or "")).strip() or fallback
    if any(ord(char) < 32 for char in name):
        fail("节点名称包含控制字符")
    return name[:160]


def query_value(query, *names, default=""):
    for name in names:
        values = query.get(name)
        if values:
            return values[0]
    return default


def endpoint(parts):
    try:
        host = parts.hostname
        port = parts.port
    except ValueError:
        fail("节点地址或端口无效")
    if not host:
        fail("节点缺少服务器地址")
    return host, as_port(port)


def add_transport(node, network, query):
    network = (network or "tcp").lower()
    if network not in ("tcp", "none"):
        node["network"] = network
    if network == "ws":
        ws_opts = {"path": unquote(query_value(query, "path", default="/")) or "/"}
        host = query_value(query, "host")
        if host:
            ws_opts["headers"] = {"Host": unquote(host)}
        node["ws-opts"] = ws_opts
    elif network == "grpc":
        service = query_value(query, "serviceName", "service-name", "path")
        if service:
            node["grpc-opts"] = {"grpc-service-name": unquote(service)}
    elif network in ("http", "h2"):
        path = unquote(query_value(query, "path", default="/")) or "/"
        http_opts = {"path": [path]}
        host = query_value(query, "host")
        if host:
            http_opts["headers"] = {"Host": [unquote(host)]}
        node["http-opts"] = http_opts


def add_tls(node, query, security=""):
    security = (security or query_value(query, "security")).lower()
    if security in ("tls", "reality", "xtls"):
        node["tls"] = True
    sni = query_value(query, "sni", "servername", "peer")
    if sni:
        node["servername"] = unquote(sni)
    if as_bool(query_value(query, "allowInsecure", "insecure", "skip-cert-verify")):
        node["skip-cert-verify"] = True
    fingerprint = query_value(query, "fp", "fingerprint")
    if fingerprint:
        node["client-fingerprint"] = fingerprint
    alpn = query_value(query, "alpn")
    if alpn:
        node["alpn"] = [item for item in unquote(alpn).split(",") if item]
    if security == "reality":
        public_key = query_value(query, "pbk", "public-key")
        short_id = query_value(query, "sid", "short-id")
        if not public_key:
            fail("Reality 节点缺少公钥 pbk")
        reality = {"public-key": public_key}
        if short_id:
            reality["short-id"] = short_id
        node["reality-opts"] = reality


def parse_vmess(uri):
    payload = json.loads(decode_base64(uri[len("vmess://") :]))
    if not isinstance(payload, dict):
        fail("VMess 内容不是对象")
    server = str(payload.get("add") or payload.get("server") or "").strip()
    if not server:
        fail("VMess 节点缺少服务器地址")
    port = as_port(payload.get("port"))
    uuid = str(payload.get("id") or payload.get("uuid") or "").strip()
    if not uuid:
        fail("VMess 节点缺少 UUID")
    node = {
        "name": clean_name(payload.get("ps"), "VMess-{}:{}".format(server, port)),
        "type": "vmess",
        "server": server,
        "port": port,
        "uuid": uuid,
        "alterId": int(payload.get("aid") or 0),
        "cipher": str(payload.get("scy") or payload.get("cipher") or "auto"),
        "udp": True,
    }
    network = str(payload.get("net") or payload.get("network") or "tcp").lower()
    query = {}
    for key in ("path", "host", "serviceName", "sni", "alpn", "fp"):
        if payload.get(key) not in (None, ""):
            query[key] = [str(payload[key])]
    add_transport(node, network, query)
    tls_value = str(payload.get("tls") or "").lower()
    add_tls(node, query, tls_value)
    if as_bool(payload.get("allowInsecure")):
        node["skip-cert-verify"] = True
    return node


def parse_standard(uri, scheme):
    parts = urlsplit(uri)
    server, port = endpoint(parts)
    query = parse_qs(parts.query, keep_blank_values=True)
    name = clean_name(parts.fragment, "{}-{}:{}".format(scheme.upper(), server, port))
    username = unquote(parts.username or "")
    password = unquote(parts.password or "")

    if scheme == "vless":
        if not username:
            fail("VLESS 节点缺少 UUID")
        node = {"name": name, "type": "vless", "server": server, "port": port,
                "uuid": username, "udp": True}
        flow = query_value(query, "flow")
        if flow:
            node["flow"] = flow
        network = query_value(query, "type", default="tcp")
        add_transport(node, network, query)
        add_tls(node, query)
        return node

    if scheme == "trojan":
        secret = username or password
        if not secret:
            fail("Trojan 节点缺少密码")
        node = {"name": name, "type": "trojan", "server": server, "port": port,
                "password": secret, "udp": True}
        add_transport(node, query_value(query, "type", default="tcp"), query)
        add_tls(node, query, query_value(query, "security", default="tls"))
        return node

    if scheme in ("hysteria2", "hy2"):
        secret = password or username
        if not secret:
            fail("Hysteria2 节点缺少密码")
        node = {"name": name, "type": "hysteria2", "server": server, "port": port,
                "password": secret}
        sni = query_value(query, "sni", "peer")
        if sni:
            node["sni"] = unquote(sni)
        if as_bool(query_value(query, "insecure", "allowInsecure")):
            node["skip-cert-verify"] = True
        obfs = query_value(query, "obfs")
        obfs_password = query_value(query, "obfs-password", "obfsPassword")
        if obfs:
            node["obfs"] = obfs
        if obfs_password:
            node["obfs-password"] = unquote(obfs_password)
        return node

    if scheme == "tuic":
        if not username or not password:
            fail("TUIC 节点需要 UUID 和密码")
        node = {"name": name, "type": "tuic", "server": server, "port": port,
                "uuid": username, "password": password}
        node["congestion-controller"] = query_value(query, "congestion_control", "congestion-controller", default="bbr")
        node["udp-relay-mode"] = query_value(query, "udp_relay_mode", "udp-relay-mode", default="native")
        sni = query_value(query, "sni")
        if sni:
            node["sni"] = unquote(sni)
        if as_bool(query_value(query, "allowInsecure", "insecure")):
            node["skip-cert-verify"] = True
        alpn = query_value(query, "alpn")
        if alpn:
            node["alpn"] = [item for item in unquote(alpn).split(",") if item]
        return node

    fail("暂不支持该节点协议")


def parse_ss(uri):
    raw = uri[len("ss://") :]
    without_fragment, _, fragment = raw.partition("#")
    main, _, query_text = without_fragment.partition("?")
    if "@" in main:
        userinfo, address = main.rsplit("@", 1)
        decoded_userinfo = unquote(userinfo)
        if ":" not in decoded_userinfo:
            decoded_userinfo = decode_base64(decoded_userinfo)
    else:
        decoded = decode_base64(main)
        if "@" not in decoded:
            fail("SS 节点格式无效")
        decoded_userinfo, address = decoded.rsplit("@", 1)
    if ":" not in decoded_userinfo:
        fail("SS 节点缺少加密方式或密码")
    cipher, secret = decoded_userinfo.split(":", 1)
    parts = urlsplit("//" + address)
    server, port = endpoint(parts)
    node = {"name": clean_name(fragment, "SS-{}:{}".format(server, port)),
            "type": "ss", "server": server, "port": port,
            "cipher": cipher, "password": unquote(secret), "udp": True}
    query = parse_qs(query_text, keep_blank_values=True)
    plugin_text = unquote(query_value(query, "plugin"))
    if plugin_text:
        plugin_parts = plugin_text.split(";")
        node["plugin"] = plugin_parts[0]
        options = {}
        for item in plugin_parts[1:]:
            if "=" in item:
                key, value = item.split("=", 1)
                options[key] = value
            elif item:
                options[item] = True
        if options:
            node["plugin-opts"] = options
    return node


def validate_node(node):
    if not isinstance(node, dict):
        fail("节点必须是 JSON 对象")
    for key in ("name", "type", "server", "port"):
        if key not in node or node[key] in (None, ""):
            fail("节点缺少字段：{}".format(key))
    node["name"] = clean_name(node["name"], "Manual-Node")
    node["type"] = str(node["type"]).lower()
    node["server"] = str(node["server"]).strip()
    if not node["server"]:
        fail("节点服务器地址为空")
    node["port"] = as_port(node["port"])
    encoded = json.dumps(node, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > 32768:
        fail("单节点内容超过 32 KiB")
    return node


def parse(raw):
    value = raw.strip()
    if not value:
        fail("请输入单节点分享链接或 Clash JSON")
    if value.startswith("{"):
        return validate_node(json.loads(value))
    lowered = value.lower()
    if lowered.startswith("vmess://"):
        node = parse_vmess(value)
    elif lowered.startswith("ss://"):
        node = parse_ss(value)
    else:
        scheme = urlsplit(value).scheme.lower()
        if scheme not in ("vless", "trojan", "hysteria2", "hy2", "tuic"):
            fail("仅支持 ss、vmess、vless、trojan、hysteria2/hy2、tuic 或 Clash JSON")
        node = parse_standard(value, scheme)
    return validate_node(node)


def main():
    try:
        raw = sys.stdin.read(65537)
        if len(raw.encode("utf-8")) > 65536:
            fail("单节点输入超过 64 KiB")
        node = parse(raw)
        sys.stdout.write(json.dumps(node, ensure_ascii=False, separators=(",", ":")))
        sys.stdout.write("\n")
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        sys.stderr.write("{}\n".format(str(exc) or "单节点格式无效"))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

