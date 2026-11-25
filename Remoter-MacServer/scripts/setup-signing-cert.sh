#!/usr/bin/env bash
# 为本机创建长期本地代码签名证书 "Remoter" 并导入登录钥匙串（免弹窗授权 codesign）。
# 只需在本机终端运行一次，之后每次 build-app.sh 重编都不会再触发 macOS 音频/屏幕权限弹窗。
set -euo pipefail

if security find-identity -p codesigning 2>/dev/null | grep -q '"Remoter"'; then
    echo "✅ 本机已存在 \"Remoter\" 代码签名证书："
    security find-identity -p codesigning | grep '"Remoter"'
    exit 0
fi

TMPDIR_CERT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_CERT"' EXIT

cat > "$TMPDIR_CERT/cs.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Remoter
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMPDIR_CERT/remoter.key" -out "$TMPDIR_CERT/remoter.crt" \
    -config "$TMPDIR_CERT/cs.cnf" 2>/dev/null

openssl pkcs12 -export -legacy -inkey "$TMPDIR_CERT/remoter.key" -in "$TMPDIR_CERT/remoter.crt" \
    -out "$TMPDIR_CERT/remoter.p12" -passout pass:remoter-tmp 2>/dev/null || \
openssl pkcs12 -export -inkey "$TMPDIR_CERT/remoter.key" -in "$TMPDIR_CERT/remoter.crt" \
    -out "$TMPDIR_CERT/remoter.p12" -passout pass:remoter-tmp 2>/dev/null

security import "$TMPDIR_CERT/remoter.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -P remoter-tmp \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "✅ 已创建并导入 \"Remoter\" 代码签名证书："
security find-identity -p codesigning | grep '"Remoter"'
echo ""
echo "提示：接下来只需重新运行 ./scripts/build-app.sh && ./scripts/install-launchagent.sh，"
echo "之后最后授权一次屏幕/音频权限即可永久生效。"
