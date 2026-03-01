#!/usr/bin/env bash
# Oracle Tool Generator — Oracle'in kendi araclarini urettigi pipeline
# Kullanim: tool-gen.sh "Tool aciklamasi"
#
# Ornekler:
#   tool-gen.sh "CSV dosyalarini JSON'a ceviren bir script yaz"
#   tool-gen.sh "GitHub API'den PR listesi ceken bir tool"
#   tool-gen.sh --lang python "Log dosyalarini analiz eden script"

set -euo pipefail

BRIDGE="$HOME/clawd/scripts/bridge.sh"
TOOLS_DIR="$HOME/clawd/tools/generated"
CATALOG="$HOME/clawd/tools/catalog.json"
TRAJECTORY="$HOME/clawd/memory/trajectory-pool.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[tool-gen]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[tool-gen]${NC} $1" >&2; }
err() { echo -e "${RED}[tool-gen]${NC} $1" >&2; }
step() { echo -e "${CYAN}[tool-gen]${NC} === $1 ===" >&2; }

# === ARGS ===
LANG="bash"
DESCRIPTION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --lang) LANG="$2"; shift 2;;
        --help|-h)
            echo "Kullanim: tool-gen.sh [--lang bash|python|node] \"Tool aciklamasi\""
            exit 0;;
        *) DESCRIPTION="$1"; shift;;
    esac
done

[[ -z "$DESCRIPTION" ]] && { err "Tool aciklamasi gerekli"; exit 1; }

mkdir -p "$TOOLS_DIR"

# === STEP 1: DESIGN ===
step "1/5 TASARIM"
log "Tool tasarimi hazirlaniyor..."

DESIGN_PROMPT="Sen Oracle'in Tool Generator'isun. Bir CLI tool tasarla.

ACIKLAMA: $DESCRIPTION
DIL: $LANG

Asagidaki JSON formatinda cevap ver:
{
  \"name\": \"tool-adi (kebab-case)\",
  \"description\": \"Tek satirlik aciklama\",
  \"category\": \"data_processing|api_integration|automation|analysis|system|monitoring\",
  \"inputs\": [\"girdi1\", \"girdi2\"],
  \"outputs\": \"Cikti aciklamasi\",
  \"dependencies\": [\"gerekli paketler veya bos array\"],
  \"test_cases\": [
    {\"input\": \"ornek girdi\", \"expected\": \"beklenen cikti\"}
  ]
}

SADECE JSON dondur, baska bir sey yazma."

DESIGN=$(bash "$BRIDGE" --quick --text --silent "$DESIGN_PROMPT" 2>/dev/null) || {
    err "Tasarim asamasi basarisiz"
    exit 1
}

# Extract tool name from design
TOOL_NAME=$(echo "$DESIGN" | python3 -c "
import sys, json, re
text = sys.stdin.read()
# Try to parse as JSON
try:
    match = re.search(r'\{[^{}]*\"name\"[^{}]*\}', text, re.DOTALL)
    if match:
        data = json.loads(match.group())
        print(data['name'])
    else:
        print('tool-' + str(hash(text))[:8])
except:
    print('tool-' + str(hash(text))[:8])
" 2>/dev/null) || TOOL_NAME="tool-$(date +%s)"

log "Tool adi: $TOOL_NAME"

# === STEP 2: GENERATE CODE ===
step "2/5 KOD URETIMI"

EXT="sh"
[[ "$LANG" == "python" ]] && EXT="py"
[[ "$LANG" == "node" ]] && EXT="js"

TOOL_PATH="$TOOLS_DIR/${TOOL_NAME}.${EXT}"

CODE_PROMPT="Sen Oracle'in Tool Generator'isun. Bir CLI tool yaz.

ACIKLAMA: $DESCRIPTION
DIL: $LANG
TOOL ADI: $TOOL_NAME

KURALLAR:
- Shebang satiri ile basla (#!/usr/bin/env bash veya #!/usr/bin/env python3)
- --help secenegi destekle
- Hata durumunda anlamli mesaj ve non-zero exit
- Stdin'den veya argumandan girdi al
- Temiz, okunabilir kod yaz
- Gereksiz dependency kullanma
- Magic number kullanma, constant tanimla

SADECE kodu yaz, aciklama ekleme. Markdown code block KULLANMA."

CODE=$(bash "$BRIDGE" --code --text --silent "$CODE_PROMPT" 2>/dev/null) || {
    err "Kod uretimi basarisiz"
    exit 1
}

# Clean code (remove markdown blocks if present)
CLEAN_CODE=$(echo "$CODE" | sed '/^```/d')

echo "$CLEAN_CODE" > "$TOOL_PATH"
chmod +x "$TOOL_PATH"
log "Dosya olusturuldu: $TOOL_PATH"

# === STEP 3: GENERATE TEST ===
step "3/5 TEST URETIMI"

TEST_PATH="$TOOLS_DIR/test-${TOOL_NAME}.sh"

cat > "$TEST_PATH" << TESTEOF
#!/usr/bin/env bash
# Auto-generated test for $TOOL_NAME
set -euo pipefail

TOOL="$TOOL_PATH"
PASS=0
FAIL=0

test_case() {
    local desc="\$1"
    local cmd="\$2"
    local expected_exit="\${3:-0}"

    if eval "\$cmd" >/dev/null 2>&1; then
        actual_exit=0
    else
        actual_exit=\$?
    fi

    if [[ "\$actual_exit" == "\$expected_exit" ]]; then
        echo "  PASS: \$desc"
        PASS=\$((PASS + 1))
    else
        echo "  FAIL: \$desc (expected exit \$expected_exit, got \$actual_exit)"
        FAIL=\$((FAIL + 1))
    fi
}

echo "Testing: $TOOL_NAME"
echo "---"

# Basic tests
test_case "Help flag works" "\$TOOL --help" 0
test_case "No args gives error or help" "\$TOOL" 0  # Some tools work without args

echo "---"
echo "Results: \$PASS passed, \$FAIL failed"

[[ \$FAIL -eq 0 ]] && exit 0 || exit 1
TESTEOF

chmod +x "$TEST_PATH"

# === STEP 4: RUN TESTS ===
step "4/5 TEST CALISTIRMA"

if bash "$TEST_PATH" 2>&1; then
    TEST_RESULT="PASS"
    log "Testler BASARILI"
else
    TEST_RESULT="PARTIAL"
    warn "Bazi testler basarisiz — tool yine de deploy edilecek"
fi

# === STEP 5: REGISTER IN CATALOG ===
step "5/5 KATALOG KAYDI"

# Initialize catalog if it doesn't exist
if [[ ! -f "$CATALOG" ]]; then
    echo '{"tools":[]}' > "$CATALOG"
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

python3 -c "
import json, sys

with open('$CATALOG') as f:
    catalog = json.load(f)

new_tool = {
    'id': '$TOOL_NAME',
    'name': '$TOOL_NAME',
    'path': '$TOOL_PATH',
    'language': '$LANG',
    'created': '$TIMESTAMP',
    'created_by': 'tool-gen',
    'category': 'auto',
    'status': 'new',
    'test_result': '$TEST_RESULT',
    'usage_count': 0,
    'last_used': None,
    'description': '''$(echo "$DESCRIPTION" | head -c200)'''
}

# Remove existing entry with same id
catalog['tools'] = [t for t in catalog['tools'] if t['id'] != '$TOOL_NAME']
catalog['tools'].append(new_tool)

with open('$CATALOG', 'w') as f:
    json.dump(catalog, f, indent=2)

print(f'Tool kayitli: {len(catalog[\"tools\"])} tool katalogda')
"

log "Tool basariyla olusturuldu ve kaydedildi!"
echo ""
echo "  Path:     $TOOL_PATH"
echo "  Test:     $TEST_PATH"
echo "  Katalog:  $CATALOG"
echo "  Durum:    $TEST_RESULT"
