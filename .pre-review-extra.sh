#!/usr/bin/env bash
# free-code 的產品自訂 pre-review 閘門
#
# 由 ~/.claude/scripts/pre-review.sh 的第 3 段以 `bash .pre-review-extra.sh` 呼叫，
# 工作目錄必須是本 repo 根目錄。
#
# 為什麼需要這一支：
#   本 repo 沒有 go.mod、沒有任何 eslint 設定，pre-review.sh 的前兩段對它全部跳過。
#   在沒有這支的情況下，pre-review 會在「什麼都沒驗」的狀態下印出「通過」，
#   而假綠燈比沒有閘門更危險——它會讓 reviewer 以為機器已經把規則面掃過一遍。
#
# 本檔負責的兩段檢查（兩段都會跑完才回報，刻意不 fail-fast：
# 先壞的那一段不可以把後面那一段的問題藏起來）：
#   [1/2] 型別檢查（棘輪）：tsc 版本釘選 + 掃描範圍下限 + 錯誤數雙向鎖 + 逃生門數量雙向鎖
#   [2/2] build 冒煙：真的 build 出 ./cli，並確認產物有更新且跑得起來
#
# 結束碼：
#   0  通過
#   1  閘門不通過（把本腳本的輸出原樣退回 architect 修）
#   69 環境不可用（EX_UNAVAILABLE；這不是程式碼的問題，是這台機器缺東西，
#      不要往 architect 退，先把環境補起來再重跑）
#
# ⚠ 呼叫端只做 `bash .pre-review-extra.sh || FAIL=1`，它看不見 69 與 1 的差別，
#   而且會在本腳本的輸出之後再印一句通用結語「❌ pre-review 未通過…附給 architect」。
#   那句話是呼叫端對「非 0」的統一說法，不是對本次結果的判讀。
#   因此 die_env 會自己把這件事講清楚，並要求以 `[環境] EXIT=69` 那一段為準。

# 刻意不開 `set -e`：兩段檢查都要跑完。
# 每一個外部指令的結束碼都在下面被明確判定，沒有任何一處把結果吞掉。
set -u -o pipefail

# ---------------------------------------------------------------------------
# 棘輪基準
# ---------------------------------------------------------------------------
# 本 repo 的原始碼是從 source map 重建的，帶著大量既有型別錯誤。
# 硬性要求「零型別錯誤」會讓每一次 pre-review 都紅燈，閘門會立刻被當成雜訊繞過，
# 於是退回跟現在一樣的沒有閘門狀態。因此採棘輪：只鎖住「不准變更糟」。
#
# 基準值刻意寫成腳本內常數，而不是獨立的基準檔：
#   1. 基準一旦變動，一定出現在這支腳本自己的 diff 裡，review 時看得到；
#      放獨立檔容易演變成「腳本自動覆寫基準」，那等於讓閘門自己放寬自己。
#   2. 不會在 repo 留下未追蹤檔，也不必為它加 .gitignore 例外。
#
# 量測方式（2026-09-16，commit 6b25ab6，bun 1.4.2，TypeScript 6.0.2）：
#   bunx tsc --noEmit --ignoreDeprecations 6.0 --pretty false
#   → 1434。寬鬆數法（grep -c "error TS"）與下方的嚴格逐行錨定數法結果相同，
#     兩種數法在此基準上一致，之後若有人改數法可用這一點對帳。
#   tsc 版本是這個數字的隱含前提，不是背景資訊——見下方 TSC_VERSION_BASELINE。
TSC_ERROR_BASELINE=1434

# 量測上述基準時的 tsc 版本。
# package.json 寫的是 "typescript": "^6.0.2"（caret），任何一次 bun install 都可能
# 把它拉到 6.1.x；tsc 每個 minor 版都會增刪診斷，錯誤數會跟著動。
# 而棘輪不通過時的指示是「把基準改成 current」——在版本已經漂走的情況下照做，
# 等於把這次真正的回歸連同工具版本差異一起洗進新基準，之後再也查不出來。
# 所以基準與量測它的版本要一起釘住，不符時停下來要求人工判斷（見下方版本閘門）。
TSC_VERSION_BASELINE=6.0.2

# 型別檢查的掃描範圍下限（tsc 實際納入、且不在 node_modules 內的檔案數）。
# 2026-09-16 實測 1934。這一條是用來抓「錯誤數下降其實是因為根本沒檢查」——
# 例如有人把 tsconfig.json 的 include / paths 改小，錯誤數會漂亮地掉下來，
# 但那是檢查網破了，不是程式碼變好了。
#
# 下限取 1900（只容許 34 個檔、約 1.8% 的縮水）而不是寬鬆的 1500：
# 本 repo 絕大多數檔案是沒有型別錯誤的，1500 的下限等於允許排掉 434 個檔，
# 而排掉 434 個「無錯檔」完全可以維持 current=1434 的綠燈——那條防線形同不存在。
# 真的有大量檔案被合法刪除時，錯誤數必然也會跟著掉、本來就要人工改 TSC_ERROR_BASELINE，
# 所以「連這條一起改」不會多出額外的往返。
TSC_SCOPE_FLOOR=1900

# 型別逃生門的數量上限。`@ts-nocheck` 一行就能讓整個檔退出型別檢查，
# 錯誤數棘輪對它完全無感：新檔開頭加一行 nocheck，裡面帶多少錯誤都會數成 0，
# 綠燈通過。所以逃生門本身的數量也要被鎖住，否則棘輪只是換個姿勢被繞過。
# 2026-09-16 實測 13 處（全部是 @ts-expect-error，集中在 src/ink 的 ink 相依處）。
TS_SUPPRESS_BASELINE=13

# tsc 診斷行的嚴格錨定：診斷行一定從第 0 欄開始（`檔案(行,列): error TSxxxx: 訊息`），
# 而多行訊息的續行一定以空白開頭。用這個形狀數，可避免把續行重複計入。
TSC_DIAG_RE='^[^[:space:]].*: error TS[0-9]+: '

EXIT_ENV=69
FAIL=0

# ---------------------------------------------------------------------------
# 共用工具
# ---------------------------------------------------------------------------

# 環境不可用走獨立結束碼，並在訊息裡明講「這不是程式碼的問題」，
# 避免下一個人看到非零就以為是 architect 寫壞了而去改 code。
die_env() {
  echo ""
  echo "[環境] EXIT=${EXIT_ENV} $1"
  echo "[環境] 這是這台機器的環境問題，不是本次程式碼變更的問題；"
  echo "[環境] 請先修環境再重跑 pre-review，不要退回 architect 改 code。"
  # 呼叫端 pre-review.sh 只判斷「非 0 即失敗」，會在本段之後再印一句它自己的通用結語，
  # 把 69 跟 1 講成同一件事。那句話在畫面上排在最後、最容易被當成結論，
  # 所以這裡先把它點名，免得下一個人照著那句話把環境問題退給 architect 改 code。
  echo "[環境] 下方若出現「❌ pre-review 未通過…請將上述輸出原樣附給 architect」，"
  echo "[環境] 那是呼叫端對任何非 0 結束碼的通用結語，不是對本次結果的判讀；"
  echo "[環境] 本次請以本段 [環境] EXIT=${EXIT_ENV} 為準。"
  exit "$EXIT_ENV"
}

fail_gate() {
  echo "[不通過] $1"
  FAIL=1
}

# 型別檢查單趟的時間上限（秒）。
# pre-review 是被自動化串起來呼叫的，沒有人坐在旁邊按 Ctrl-C；tsc 一旦卡住
# （9p 檔案系統抖動、記憶體吃緊前的顛簸）整個流程會無限期掛在這裡，
# 而「掛住」比「失敗」難查得多——它不會留下任何結論。
# 正常一趟約 15 秒，600 秒是 40 倍餘裕，只在真的卡死時才會踩到。
TSC_TIMEOUT_SEC=600

# 包 timeout 的 tsc 呼叫。timeout 自己不存在時退回直接執行：
# 缺這支工具不該讓型別檢查整段不跑。
run_tsc() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TSC_TIMEOUT_SEC" bunx tsc "$@"
  else
    bunx tsc "$@"
  fi
}

TMP_DIR=""
cleanup() {
  # 暫存一律放系統暫存目錄，不在 repo 內產生任何檔案，
  # 讓跑完之後 `git status --porcelain` 仍然是空的。
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
  return 0
}
trap cleanup EXIT
# 訊號也各補一次 cleanup，並以 128+訊號 結束（cleanup 可重入，多跑一次沒有副作用）。
#
# 2026-09-16 用反例實測過這三行到底擋下了什麼，結論與直覺不同，寫在這裡免得
# 下一個人把它當成「不加就會漏暫存」而誤判：
#   - TERM / INT：bash 自己的 termsig_handler 在退出前就會跑 EXIT trap，
#     把這三行刪掉再用 `timeout -s TERM` 砍，/tmp 一樣是乾淨的——對這兩個訊號它是冗餘的。
#   - KILL：實測會留下 /tmp/tmp.xxxxx，而且 trap 攔不到 SIGKILL，這三行也救不了。
# 保留的理由是「顯式勝過依賴 shell 的隱含行為」（EXIT trap 在訊號下會跑是 bash 的實作細節，
# 不是規格保證），成本為零；但不要指望它能處理被強制 KILL 的情況。
# 真正的保險是 cleanup 只碰系統暫存目錄：即使殘留也留在 /tmp，repo 內永遠是乾淨的。
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# ---------------------------------------------------------------------------
# 前置：確認「該有的輸入」都在，缺了就硬失敗而不是靜默跳過
# ---------------------------------------------------------------------------

if [ ! -f package.json ] || [ ! -f tsconfig.json ] || [ ! -d src ]; then
  die_env "目前目錄 $(pwd) 看起來不是 free-code repo 根目錄（缺 package.json / tsconfig.json / src）。"
fi

# pre-review.sh 有可能被非 login shell 呼叫，那時 PATH 不含 ~/.bun/bin。
if ! command -v bunx >/dev/null 2>&1; then
  if [ -x "$HOME/.bun/bin/bunx" ]; then
    PATH="$HOME/.bun/bin:$PATH"
    export PATH
  else
    die_env "找不到 bunx。本 repo 的工具鏈只在 WSL 內（$HOME/.bun/bin/bun），Windows 側沒有。"
  fi
fi

if [ ! -d node_modules/typescript ]; then
  die_env "找不到 node_modules/typescript，型別檢查無法進行。請先執行：bun install"
fi

TMP_DIR="$(mktemp -d)" || die_env "無法建立暫存目錄。"
TSC_OUT="$TMP_DIR/tsc.txt"
TSC_LIST="$TMP_DIR/tsc-files.txt"

# ---------------------------------------------------------------------------
# 工具鏈版本：棘輪基準的隱含前提，印出來讓它不再是隱含的
# ---------------------------------------------------------------------------
TSC_VERSION_RAW="$(bunx tsc --version 2>&1)"
TSC_VERSION_PROBE_EXIT=$?
if [ "$TSC_VERSION_PROBE_EXIT" -ne 0 ]; then
  echo "$TSC_VERSION_RAW"
  die_env "bunx tsc --version 執行失敗（exit=${TSC_VERSION_PROBE_EXIT}），tsc 根本跑不起來。"
fi
# tsc 的輸出形如 `Version 6.0.2`，取最後一個空白之後的字串。
TSC_VERSION="${TSC_VERSION_RAW##* }"

echo "=== [free-code] 工具鏈：TypeScript ${TSC_VERSION}（基準量測於 ${TSC_VERSION_BASELINE}）==="

# 版本不符時，錯誤數的任何變動都同時有「程式碼」與「工具」兩個可能來源，
# 無法歸因。這一句會被接到下面兩個棘輪訊息後面，攔住「照指示把基準改成 current」
# 這個在版本漂走時會把真回歸一起洗掉的反射動作。
TSC_VERSION_NOTE=""
if [ "$TSC_VERSION" != "$TSC_VERSION_BASELINE" ]; then
  TSC_VERSION_NOTE="
           ⚠ 而且 tsc 版本已經不是量測基準的那一版（${TSC_VERSION_BASELINE} → ${TSC_VERSION}），
           這個差額有可能根本不是程式碼造成的。先把版本釘回去重跑，確認差額仍在，再改基準。"
  fail_gate "TypeScript 版本與棘輪基準的量測版本不符：${TSC_VERSION_BASELINE} → ${TSC_VERSION}。
           package.json 是 \"typescript\": \"^6.0.2\"（caret），bun install 會自己往上跳 minor，
           而基準 ${TSC_ERROR_BASELINE} 是在 ${TSC_VERSION_BASELINE} 上量出來的，換版本後這個數字就換了意義。
           不打算跟進新版本：bun add -D typescript@${TSC_VERSION_BASELINE} 釘回去再重跑。
           要跟進新版本：先在【不含本次程式碼變更】的狀態下量一次新版本的錯誤數，
           確認差額純屬工具差異（不含真回歸），再把 TSC_VERSION_BASELINE 與 TSC_ERROR_BASELINE
           一起改掉，放同一個 commit 並在 commit message 寫明是版本跟進。"
fi

# ---------------------------------------------------------------------------
# [1/2] 型別檢查（棘輪）
# ---------------------------------------------------------------------------
echo "=== [free-code 1/2] 型別檢查（棘輪 baseline=${TSC_ERROR_BASELINE}）==="

# `--ignoreDeprecations 6.0` 只下在 CLI，不寫進 tsconfig.json：
# tsconfig.json 會被所有開發者與各自的 IDE 讀到，為了這個閘門去動它影響面過大。
# 不加這個旗標的話，baseUrl 的 TS5101 是 config 層錯誤，tsc 會在檢查任何原始碼之前就中止，
# 整個型別檢查等於沒跑（而且只吐 1 行，看起來還像是「幾乎沒有錯誤」）。
TSC_FLAGS=(--noEmit --ignoreDeprecations 6.0 --pretty false)

# 先量掃描範圍。--listFilesOnly 不做型別檢查，約 0.6 秒，
# 是「這次到底掃了多少東西」唯一能在零錯誤時仍然成立的存活訊號。
run_tsc "${TSC_FLAGS[@]}" --listFilesOnly > "$TSC_LIST" 2>&1
TSC_LIST_EXIT=$?

# 124 是 timeout 的專用碼：tsc 卡死是環境問題，退給 architect 改 code 沒有意義。
if [ "$TSC_LIST_EXIT" -eq 124 ]; then
  die_env "tsc --listFilesOnly 超過 ${TSC_TIMEOUT_SEC} 秒仍未結束，已被 timeout 中止（正常約 1 秒）。"
fi

if [ "$TSC_LIST_EXIT" -ne 0 ]; then
  echo "--- tsc --listFilesOnly 的診斷 ---"
  # 只印診斷行：這個輸出的其餘部分是成千上百行檔案清單，全印會把錯誤訊息淹掉。
  grep -E 'error TS' "$TSC_LIST" > "$TMP_DIR/list-diag.txt"
  if [ -s "$TMP_DIR/list-diag.txt" ]; then
    head -10 "$TMP_DIR/list-diag.txt"
  else
    head -5 "$TSC_LIST"
  fi
  fail_gate "tsc 無法列出檢查範圍（exit=${TSC_LIST_EXIT}），tsconfig.json 或 CLI 旗標可能有問題。"
  TSC_SCOPE=0
else
  # 只數專案自己的檔（node_modules 內的型別宣告不算掃描範圍）。
  TSC_SCOPE=$(grep -v '/node_modules/' "$TSC_LIST" | wc -l | tr -d '[:space:]')
  echo "掃描範圍：${TSC_SCOPE} 個專案檔（不含 node_modules；下限 ${TSC_SCOPE_FLOOR}）"
  if [ "$TSC_SCOPE" -lt "$TSC_SCOPE_FLOOR" ]; then
    fail_gate "型別檢查掃描範圍只剩 ${TSC_SCOPE} 個檔，低於下限 ${TSC_SCOPE_FLOOR}。
           錯誤數在這種狀態下就算沒增加也不代表安全——請先確認 tsconfig.json 的
           include / paths 是不是被改小了。"
  fi
fi

# 正式的型別檢查。
run_tsc "${TSC_FLAGS[@]}" > "$TSC_OUT" 2>&1
TSC_EXIT=$?

if [ "$TSC_EXIT" -eq 124 ]; then
  die_env "tsc 超過 ${TSC_TIMEOUT_SEC} 秒仍未結束，已被 timeout 中止（正常約 15 秒）。"
fi

# 用 wc 取數而不是 grep -c：grep 在「0 筆」時結束碼是 1，
# 用 wc 可以讓「0 筆」是一個明確的數值，而不必用 `|| true` 去遮蔽 grep 的結束碼。
# tsc 自己的結果沒有被吞掉——TSC_EXIT 在下面每一條分支都會被判定。
TSC_CURRENT=$(grep -E "$TSC_DIAG_RE" "$TSC_OUT" | wc -l | tr -d '[:space:]')

# config 層錯誤（診斷指向 tsconfig.json 本身，或完全沒有檔案前綴的 CLI 參數錯誤）
# 代表 tsc 根本沒進到原始碼就中止了。這種情況下錯誤數會極低，
# 若不特判，棘輪會把它讀成「錯誤大幅減少」，是本閘門最危險的假訊號。
TSC_CONFIG_ERR=$(grep -Ec '^(tsconfig\.json\(|error TS)' "$TSC_OUT" | tr -d '[:space:]')

echo "tsc exit=${TSC_EXIT}  baseline=${TSC_ERROR_BASELINE}  current=${TSC_CURRENT}"

if [ "$TSC_CONFIG_ERR" -gt 0 ]; then
  echo "--- tsc 輸出（config 層）---"
  grep -E '^(tsconfig\.json\(|error TS)' "$TSC_OUT" | head -10
  fail_gate "型別檢查沒有真正執行：tsc 在讀設定／參數階段就中止了。
           此時的錯誤數（${TSC_CURRENT}）不具任何意義，不可當成通過。"
elif [ "$TSC_EXIT" -ne 0 ] && [ "$TSC_CURRENT" -eq 0 ]; then
  echo "--- tsc 輸出（前 20 行）---"
  head -20 "$TSC_OUT"
  fail_gate "tsc 以非 0 結束（exit=${TSC_EXIT}）卻解析不到任何型別診斷行，
           檢查網可能破了（tsc 崩潰、被中斷、或輸出格式變了）。"
elif [ "$TSC_EXIT" -eq 0 ] && [ "$TSC_CURRENT" -ne 0 ]; then
  fail_gate "tsc 回報成功（exit=0）卻數到 ${TSC_CURRENT} 筆錯誤，兩者矛盾，判定不可信。"
elif [ "$TSC_CURRENT" -gt "$TSC_ERROR_BASELINE" ]; then
  echo "--- 新增的型別錯誤（供 architect 直接修）---"
  # 以下只影響輸出可讀性，不影響判定：把「最近動過的檔案」的錯誤挑出來先印，
  # 讓 architect 不必在上千行既有錯誤裡撈自己這次新增的那幾行。
  # 涵蓋兩種來源：工作區尚未 commit 的改動，以及 HEAD 這一個 commit 改到的檔
  # （五步驟裡 architect 是先 commit 才跑 pre-review，工作區通常是乾淨的）。
  {
    git status --porcelain 2>/dev/null | sed 's/^...//'
    if git rev-parse --verify -q HEAD~1 >/dev/null 2>&1; then
      git diff --name-only HEAD~1 HEAD 2>/dev/null
    fi
  } | sed '/^$/d' | sort -u | sed 's/$/(/' > "$TMP_DIR/changed.txt"

  grep -F -f "$TMP_DIR/changed.txt" "$TSC_OUT" | head -40 > "$TMP_DIR/suspect.txt"

  if [ -s "$TMP_DIR/suspect.txt" ]; then
    cat "$TMP_DIR/suspect.txt"
  else
    echo "（最近動過的檔案裡找不到型別錯誤；以下是完整清單的前 40 行）"
    head -40 "$TSC_OUT"
  fi
  echo "（完整結果請自行執行：bunx tsc --noEmit --ignoreDeprecations 6.0 --pretty false）"
  fail_gate "型別錯誤數增加：${TSC_ERROR_BASELINE} → ${TSC_CURRENT}（+$((TSC_CURRENT - TSC_ERROR_BASELINE))）。
           本 repo 允許既有錯誤存在，但不允許這次改動讓它變多。${TSC_VERSION_NOTE}"
elif [ "$TSC_CURRENT" -lt "$TSC_ERROR_BASELINE" ]; then
  # 棘輪要能往下鎖：錯誤變少是好事，但基準沒跟著降下來，
  # 那段空隙之後會被新的錯誤填回去而且不會被擋（1434 的基準可以無聲吸收 34 個新錯誤）。
  # 另外，錯誤數下降也可能是「檢查範圍縮了」的症狀，本來就該停下來看一眼再放行。
  fail_gate "型別錯誤數下降：${TSC_ERROR_BASELINE} → ${TSC_CURRENT}（-$((TSC_ERROR_BASELINE - TSC_CURRENT))）。
           這通常是好事，但棘輪必須往下鎖，否則舊基準會留下 $((TSC_ERROR_BASELINE - TSC_CURRENT)) 個名額
           讓之後新增的錯誤無聲通過。
           請把本檔的 TSC_ERROR_BASELINE 改成 ${TSC_CURRENT}（放進同一個 commit）後重跑。
           若掃描範圍那一行的數字也一起掉了，先確認不是 tsconfig.json 的 include 被改小。${TSC_VERSION_NOTE}"
else
  echo "[通過] 型別錯誤數維持在基準 ${TSC_ERROR_BASELINE}，未增加。"
fi

# --- 型別逃生門棘輪 ---------------------------------------------------------
# 錯誤數棘輪只鎖住「被 tsc 數到的錯誤」，對「叫 tsc 不要看」完全無感：
# 新檔開頭一行 @ts-nocheck，裡面塞多少型別錯誤都會數成 0，然後綠燈通過。
# 所以逃生門的數量本身要一起鎖，否則上面那道棘輪只是換個姿勢被繞過。
# 計數範圍取 tsconfig.json 的 include 集合（src / scripts / env.d.ts）；
# -I 讓 src/vendor 底下的二進位檔（ripgrep 等）不參與比對，數字才穩定可重現。
TS_SUPPRESS_RE='@ts-(ignore|expect-error|nocheck)'

# 先確認計數來源都在。少了其中一個時 grep 只會少數幾筆，結果會被下面讀成
# 「逃生門減少」——一個完全誤導的結論（實際上是計數範圍與型別檢查範圍對不起來了）。
TS_SUPPRESS_MISSING=""
for TS_SUPPRESS_PATH in src scripts env.d.ts; do
  [ -e "$TS_SUPPRESS_PATH" ] || TS_SUPPRESS_MISSING="${TS_SUPPRESS_MISSING} ${TS_SUPPRESS_PATH}"
done

if [ -n "$TS_SUPPRESS_MISSING" ]; then
  fail_gate "逃生門計數的來源不存在：${TS_SUPPRESS_MISSING}。
           這幾個路徑是 tsconfig.json 的 include 集合（src / scripts / env.d.ts）；
           少了任何一個，計數範圍就與型別檢查範圍對不起來，這時的逃生門數字不具意義。
           若 include 真的改了，請同步改本檔的計數範圍與 TS_SUPPRESS_BASELINE。"
  TS_SUPPRESS_CURRENT=-1
else
  TS_SUPPRESS_CURRENT=$(grep -rIEo "$TS_SUPPRESS_RE" src scripts env.d.ts | wc -l | tr -d '[:space:]')
  echo "型別逃生門：${TS_SUPPRESS_CURRENT} 處（基準 ${TS_SUPPRESS_BASELINE}；@ts-ignore / @ts-expect-error / @ts-nocheck）"
fi

if [ "$TS_SUPPRESS_CURRENT" -lt 0 ]; then
  : # 來源缺件，上面已判定失敗，不再用一個沒有意義的數字去比棘輪
elif [ "$TS_SUPPRESS_CURRENT" -gt "$TS_SUPPRESS_BASELINE" ]; then
  echo "--- 目前所有逃生門的位置（新增的那幾處在其中）---"
  grep -rIEno "$TS_SUPPRESS_RE" src scripts env.d.ts | head -40
  fail_gate "型別逃生門增加：${TS_SUPPRESS_BASELINE} → ${TS_SUPPRESS_CURRENT}（+$((TS_SUPPRESS_CURRENT - TS_SUPPRESS_BASELINE))）。
           這次改動多了關閉型別檢查的註解，錯誤數棘輪看不到被它遮住的東西。
           請改成真的處理型別；確實非壓不可時，把本檔的 TS_SUPPRESS_BASELINE 調成
           ${TS_SUPPRESS_CURRENT} 並在 commit message 說明為什麼那一處只能壓。"
elif [ "$TS_SUPPRESS_CURRENT" -lt "$TS_SUPPRESS_BASELINE" ]; then
  fail_gate "型別逃生門減少：${TS_SUPPRESS_BASELINE} → ${TS_SUPPRESS_CURRENT}（-$((TS_SUPPRESS_BASELINE - TS_SUPPRESS_CURRENT))）。
           這是好事，但跟錯誤數棘輪一樣要往下鎖：基準不跟著降，就留下
           $((TS_SUPPRESS_BASELINE - TS_SUPPRESS_CURRENT)) 個名額讓之後新加的逃生門無聲通過。
           請把本檔的 TS_SUPPRESS_BASELINE 改成 ${TS_SUPPRESS_CURRENT}（放進同一個 commit）後重跑。"
fi

# ---------------------------------------------------------------------------
# [2/2] build 冒煙
# ---------------------------------------------------------------------------
echo ""
echo "=== [free-code 2/2] build 冒煙 ==="

# 用完整精度的 mtime 當前後對照：只看 `bun run build` 的結束碼不夠，
# 「exit 0 但產物沒被寫出來」是這類打包步驟典型的無聲失敗。
CLI_MTIME_BEFORE="$(stat -c '%.Y' cli 2>/dev/null)"
if [ -z "$CLI_MTIME_BEFORE" ]; then
  CLI_MTIME_BEFORE="(不存在)"
fi
echo "build 前 ./cli mtime：${CLI_MTIME_BEFORE}"

bun run build
BUILD_EXIT=$?

CLI_MTIME_AFTER="$(stat -c '%.Y' cli 2>/dev/null)"
echo "build 後 ./cli mtime：${CLI_MTIME_AFTER:-(不存在)}"

if [ "$BUILD_EXIT" -ne 0 ]; then
  fail_gate "bun run build 失敗（exit=${BUILD_EXIT}）。"
elif [ -z "$CLI_MTIME_AFTER" ]; then
  fail_gate "bun run build 回報成功，但產物 ./cli 不存在。"
elif [ "$CLI_MTIME_AFTER" = "$CLI_MTIME_BEFORE" ]; then
  fail_gate "bun run build 回報成功，但產物 ./cli 的 mtime 沒有變動，這次並沒有真的產出東西。"
else
  # 產物要能起得來才算冒煙成功。--version 不需要任何 provider 憑證、不會發出網路請求，
  # 是這支 CLI 成本最低又真的會把 bundle 載進來執行一次的路徑。
  # timeout 只是防呆；它自己不存在時要退回直接執行，
  # 否則 127 會被下面判成「產物跑不起來」，把環境問題誣賴給程式碼。
  if command -v timeout >/dev/null 2>&1; then
    CLI_VERSION="$(timeout 60 ./cli --version 2>&1)"
  else
    CLI_VERSION="$(./cli --version 2>&1)"
  fi
  CLI_VERSION_EXIT=$?
  echo "./cli --version → ${CLI_VERSION}"
  if [ "$CLI_VERSION_EXIT" -ne 0 ]; then
    fail_gate "產物 ./cli 執行 --version 失敗（exit=${CLI_VERSION_EXIT}），build 出來的東西跑不起來。"
  elif [ -z "$CLI_VERSION" ]; then
    fail_gate "產物 ./cli 執行 --version 沒有任何輸出。"
  else
    echo "[通過] build 產出 ./cli 並成功執行。"
  fi
fi

# ---------------------------------------------------------------------------
# 結論
# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "[不通過] free-code 產品自訂檢查未通過（型別棘輪 / build 冒煙，見上方各段）。"
  exit 1
fi
echo "[通過] free-code 產品自訂檢查：型別棘輪 + build 冒煙。"
exit 0
