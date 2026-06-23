#!/bin/bash
# =============================================================
# WebSocket Connection Diagnostics
# Запустите: bash diagnose_ws.sh
# По умолчанию проверяет localhost:8080 — измените PORT ниже
# =============================================================

HOST="${1:-localhost}"
PORT="${2:-8080}"

echo "========================================"
echo "  WebSocket Diagnostic Tool"
echo "  Target: $HOST:$PORT"
echo "========================================"
echo ""

# --- 1. TCP connectivity check ---
echo "[ 1 ] TCP connectivity (nc)..."
if nc -z -w3 "$HOST" "$PORT" 2>/dev/null; then
  echo "  ✅ TCP port $PORT is open"
else
  echo "  ❌ TCP port $PORT is CLOSED or unreachable"
  echo "     → Server is not running, or wrong host/port"
  exit 1
fi
echo ""

# --- 2. HTTP root handler ---
echo "[ 2 ] HTTP GET / ..."
HTTP_RESP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$HOST:$PORT/")
if [ "$HTTP_RESP" = "200" ]; then
  echo "  ✅ HTTP root responded: $HTTP_RESP"
else
  echo "  ⚠️  HTTP root responded: $HTTP_RESP (expected 200)"
fi
echo ""

# --- 3. WebSocket upgrade attempt ---
echo "[ 3 ] WebSocket upgrade request to /ws ..."
WS_RESP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  --http1.1 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "http://$HOST:$PORT/ws")

if [ "$WS_RESP" = "101" ]; then
  echo "  ✅ WebSocket upgrade succeeded (101 Switching Protocols)"
  echo "     → Server-side routing is CORRECT"
elif [ "$WS_RESP" = "200" ] || [ "$WS_RESP" = "404" ] || [ "$WS_RESP" = "500" ]; then
  echo "  ❌ WebSocket upgrade FAILED — got HTTP $WS_RESP"
  echo "     → Problem is on the SERVER side (routing bug)"
  echo "     → Check that /ws route goes through webSocketHandler"
  echo "        and NOT through shelf_router directly"
else
  echo "  ⚠️  Unexpected HTTP code: $WS_RESP"
fi
echo ""

# --- 4. Verbose curl output for deeper inspection ---
echo "[ 4 ] Full WebSocket upgrade headers..."
echo "----------------------------------------"
curl -v --max-time 5 \
  --http1.1 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "http://$HOST:$PORT/ws" 2>&1 | grep -E "^[<>*]"
echo "----------------------------------------"
echo ""

# --- 5. Summary ---
echo "========================================"
echo "  Interpretation Guide"
echo "========================================"
echo "  101  → ✅ Server OK. Problem is on the client side."
echo "  404  → ❌ /ws route not registered. Fix main.dart routing."
echo "  500  → ❌ Server crash on upgrade. Check Dart logs."
echo "  200  → ❌ WebSocket handler not reached; got plain HTTP."
echo "  000  → ❌ Connection refused or timed out."
echo "========================================"