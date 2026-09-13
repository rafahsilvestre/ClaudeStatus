#!/bin/bash
# Monta ClaudeBarLocal.app a partir do arquivo Swift, sem projeto Xcode.
# Precisa apenas de: xcode-select --install
set -euo pipefail

cd "$(dirname "$0")"

APP="ClaudeBarLocal.app"
BIN_DIR="$APP/Contents/MacOS"
MIN_MACOS="13.0"

command -v swiftc >/dev/null || {
  echo "swiftc nao encontrado. Rode: xcode-select --install" >&2
  exit 1
}

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeBarLocal</string>
  <key>CFBundleDisplayName</key><string>Claude Bar Local</string>
  <key>CFBundleIdentifier</key><string>local.claudebar</string>
  <key>CFBundleExecutable</key><string>ClaudeBarLocal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <!-- LSUIElement: sem icone no Dock, so na menu bar -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

ARCH="$(uname -m)"   # arm64 ou x86_64

# Qual SDK usar. O padrao, quase sempre -- mas nao quando ele e mais novo que a
# toolchain instalada.
#
# O SwiftUI do SDK 27 declara @State como *macro*, e quem expande macro e um
# plugin (libSwiftUIMacros.dylib) que so vem com o Xcode completo: os Command
# Line Tools sozinhos nao o trazem. Numa maquina so com CLT, compilar contra o
# SDK mais novo morre em "plugin for module 'SwiftUIMacros' not found" -- em
# codigo que compilava na semana passada, porque quem mudou foi a ferramenta.
# Nesse caso caimos para o SDK mais novo que ainda compile, onde @State e um
# property wrapper comum. Com Xcode instalado o probe passa de primeira e nada
# disso acontece.
#
# O probe custa 0.35s e evita descobrir o problema depois de dez segundos de
# compilacao do app inteiro.
SDK_FLAGS=()
PROBE="$(mktemp -t claudebar-probe)"; PROBE="$PROBE.swift"
printf 'import SwiftUI\nstruct Probe: View {\n  @State private var x = 0\n  var body: some View { Text("\\(x)") }\n}\n' > "$PROBE"
probe_ok() { swiftc -typecheck -parse-as-library -target "${ARCH}-apple-macos${MIN_MACOS}" "$@" "$PROBE" 2>/dev/null; }

if ! probe_ok; then
  for sdk in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
    if probe_ok -sdk "$sdk"; then
      SDK_FLAGS=(-sdk "$sdk")
      echo "SDK padrao sem plugin de macro do SwiftUI; usando $(basename "$sdk")."
      break
    fi
  done
  if [ ${#SDK_FLAGS[@]} -eq 0 ]; then
    rm -f "$PROBE"
    echo "Nenhum SDK disponivel compila SwiftUI nesta maquina." >&2
    echo "Instale o Xcode (ou reinstale os Command Line Tools) e rode de novo." >&2
    exit 1
  fi
fi
rm -f "$PROBE"

echo "Compilando (${ARCH}, macOS ${MIN_MACOS}+)..."
# -parse-as-library: sem isso, um .swift unico compila em modo script e o @main
# e rejeitado ("'main' attribute cannot be used in a module that contains top-level code").
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  "${SDK_FLAGS[@]}" \
  -framework SwiftUI -framework AppKit \
  -o "$BIN_DIR/ClaudeBarLocal" \
  ClaudeBarLocal.swift

# Atributos estendidos fazem o codesign recusar o bundle com
# "resource fork, Finder information, or similar detritus not allowed".
#
# Esta pasta esta dentro do Desktop sincronizado por iCloud, e o file provider
# reinsere com.apple.FinderInfo na raiz do bundle em segundos -- entao nao basta
# limpar uma vez: limpa a raiz imediatamente antes de cada tentativa.
xattr -cr "$APP" 2>/dev/null || true

signed=0
for _ in 1 2 3; do
  xattr -c "$APP" 2>/dev/null || true
  # Assinatura ad-hoc: suficiente para rodar local, sem conta de developer.
  # (O app nao le Keychain, entao rebuild nao dispara nenhum prompt.)
  if codesign --force --sign - "$APP" 2>/dev/null; then
    signed=1
    break
  fi
done

if [ "$signed" != "1" ]; then
  echo "codesign falhou (xattrs do iCloud). Assinando via staging fora da pasta sincronizada..." >&2
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/" \
    && xattr -cr "$STAGE/$APP" \
    && codesign --force --sign - "$STAGE/$APP" \
    && rm -rf "$APP" \
    && cp -R "$STAGE/$APP" "$APP"
  rm -rf "$STAGE"
fi

codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true

echo ""
echo "Pronto: $(pwd)/$APP"
echo "Testar:   open $APP"
echo "Instalar: cp -R $APP /Applications/"
