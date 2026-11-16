#!/bin/bash
# x395-golden-prep.sh  —  Liberator(macOS 27)を試す前の準備を macOS 26 上で完結させる。
#
#   bash x395-golden-prep.sh            ← これだけでOK(USB を自動検出 → 確認 → バックアップ+診断)
#   bash x395-golden-prep.sh check      確認だけ(何も書き込まない)
#   bash x395-golden-prep.sh backup     EFI のバックアップだけ
#   オプション:
#     --dest /Volumes/名前   バックアップ先を手動指定(省略すると USB を自動検出)
#     --efi diskXsY          EFI パーティションを手動指定(自動検出で見つからない時)
#     --no-patched           config.plist.mk27(Kernel>Patch の上限だけ 27.99.99 にした見本)を作らない
#                            ※ EFI 内の config.plist は一切書き換えません
#
# 触るのは「バックアップ先への書き込み」と「EFI の一時マウント」だけ。EFI 本体は読み取り専用で扱う。
# bash 3.2(macOS 標準)で動く書き方にしてあります。

set -u
NEED_GB=92
case "${1:-}" in -h|--help) sed -n 2,13p "$0"; exit 0 ;; esac
MODE="${1:-all}"; [ $# -gt 0 ] && shift
DEST=""; EFI_DEV=""; WRITE_PATCHED=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="${2:-}"; shift 2 ;;
    --efi)  EFI_DEV="${2:-}"; shift 2 ;;
    --no-patched) WRITE_PATCHED=0; shift ;;
    -h|--help) sed -n 2,13p "$0"; exit 0 ;;
    *) echo "不明なオプション: $1"; exit 2 ;;
  esac
done
case "$MODE" in check|backup|all) ;; *) echo "mode は check / backup / all"; exit 2 ;; esac
[ "$MODE" = "check" ] && WRITE_PATCHED=0   # check は何も書き込まない

STAMP="$(date +%Y%m%d-%H%M%S)"
OK="[ OK ]"; NG="[ NG ]"; WN="[注意]"
MOUNTED_BY_US=""
FOUND_CFG=""; FOUND_MP=""; FOUND_DEV=""

cleanup() {
  if [ -n "$MOUNTED_BY_US" ]; then
    for d in $MOUNTED_BY_US; do diskutil unmount "$d" >/dev/null 2>&1; done
  fi
}
trap cleanup EXIT

[ "$(uname)" = "Darwin" ] || { echo "macOS 上で実行してください。"; exit 1; }
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) / $(uname -m)"
echo

# ---------- 1. 空き容量 ----------
check_space() {
  echo "== 空き容量 =="
  local kb gb
  kb=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
  [ -z "$kb" ] && kb=$(df -k / | awk 'NR==2{print $4}')
  gb=$(( kb / 1048576 ))
  if [ "$gb" -ge "$NEED_GB" ]; then echo "$OK 空き約 ${gb}GB (必要 約 ${NEED_GB}GB)"
  else echo "$NG 空き約 ${gb}GB。約 ${NEED_GB}GB 必要です。"; fi
  echo
}

# ---------- 2. 有線LAN / Liberator ----------
check_env() {
  echo "== 有線ネットワーク =="
  networksetup -listallhardwareports 2>/dev/null | awk '
    /Hardware Port:/ {p=$0} /Device:/ {print "  " p "  ->  " $0}' | grep -i -E "ethernet|lan|usb|thunderbolt" \
    || echo "  Ethernet 系のポートが見つかりません"
  echo "  USB-LAN を挿した状態で実行すると、ここに出ます。"
  echo "  (macOS 27 では Wi-Fi / Bluetooth が使えないので有線が必須)"
  echo
  echo "== Liberator =="
  if [ -d "/Applications/Liberator.app" ]; then echo "$OK /Applications/Liberator.app あり"
  else echo "$WN /Applications に Liberator.app がありません(Downloads 等にある場合は無視可)"; fi
  echo
  echo "== 注意 =="
  echo "  - X395 は NVIDIA GPU なしの構成。Vega iGPU は Apple のドライバが無く、基本表示(フレームバッファ)になる想定"
  echo "  - 本体キーボード/トラパが 27 で効かない可能性あり → USB キーボード/マウスを用意"
  echo
}

# ---------- 3. OpenCore の EFI を探す ----------
find_efi() {
  local devs d mp
  if [ -n "$EFI_DEV" ]; then devs="$EFI_DEV"
  else devs=$(diskutil list 2>/dev/null | awk '/ EFI EFI /{print $NF}'); fi
  [ -z "$devs" ] && return 1
  for d in $devs; do
    mp=$(diskutil info "/dev/$d" 2>/dev/null | awk -F: '/Mount Point/{sub(/^ +/,"",$2);print $2}')
    if [ -z "$mp" ]; then
      echo "  /dev/$d をマウントします(sudo のパスワードを聞かれます)" >&2
      sudo diskutil mount "/dev/$d" >/dev/null 2>&1 || continue
      MOUNTED_BY_US="$MOUNTED_BY_US /dev/$d"
      mp=$(diskutil info "/dev/$d" 2>/dev/null | awk -F: '/Mount Point/{sub(/^ +/,"",$2);print $2}')
    fi
    if [ -n "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ]; then
      FOUND_DEV="/dev/$d"; FOUND_MP="$mp"; FOUND_CFG="$mp/EFI/OC/config.plist"; return 0
    fi
  done
  return 1
}

# ---------- 3.5 バックアップ先(USB)の自動検出 ----------
pick_dest() {
  local v info n=0 i choice
  CAND=(); CAND_LABEL=()
  for v in /Volumes/*; do
    [ -d "$v" ] || continue
    info=$(diskutil info "$v" 2>/dev/null) || continue
    echo "$info" | grep -q -E "Device Location: +External|Removable Media: +Removable" || continue
    echo "$info" | grep -q -E "Volume Read-Only: +No|Read-Only Volume: +No" || continue
    CAND[$n]="$v"
    CAND_LABEL[$n]="$v  ($(echo "$info" | awk -F: '/Volume Total Space|Container Total Space/{sub(/^ +/,"",$2);print $2;exit}'))"
    n=$((n+1))
  done
  if [ "$n" -eq 0 ]; then
    echo "$NG 書き込める外付けドライブが見つかりません。USB を挿してやり直してください。"
    return 1
  elif [ "$n" -eq 1 ]; then
    DEST="${CAND[0]}"
    echo "  バックアップ先を自動検出: ${CAND_LABEL[0]}"
  else
    echo "  外付けドライブが複数あります。番号で選んでください:"
    i=0; while [ "$i" -lt "$n" ]; do echo "    $((i+1))) ${CAND_LABEL[$i]}"; i=$((i+1)); done
    printf "  番号: "; read -r choice
    case "$choice" in ''|*[!0-9]*) echo "$NG 数字を入れてください"; return 1 ;; esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || { echo "$NG 範囲外です"; return 1; }
    DEST="${CAND[$((choice-1))]}"
  fi
  printf "  %s にバックアップします。Enter で続行 / Ctrl+C で中止: " "$DEST"; read -r _
}

# ---------- 4. バックアップ ----------
do_backup() {
  echo "== EFI バックアップ =="
  if [ -z "$DEST" ]; then pick_dest || return 1; fi
  [ -d "$DEST" ] && [ -w "$DEST" ] || { echo "$NG $DEST に書き込めません"; return 1; }
  case "$(cd "$DEST" && pwd -P)" in /|/System/*|/Users/*) echo "$NG 内蔵ディスク上のようです。USB を指定してください: $DEST"; return 1 ;; esac
  find_efi || { echo "$NG OpenCore の EFI(EFI/OC/config.plist)が見つかりません。--efi diskXsY で指定してください"; diskutil list | grep -E " EFI | disk[0-9]" | sed 's/^/    /'; return 1; }
  echo "  EFI: $FOUND_DEV  (マウント先: $FOUND_MP)"
  local out="$DEST/EFI-backup-$STAMP"
  mkdir -p "$out" && ditto "$FOUND_MP/EFI" "$out/EFI" || { echo "$NG コピーに失敗"; return 1; }
  if diff -rq "$FOUND_MP/EFI" "$out/EFI" >/dev/null 2>&1; then
    echo "$OK バックアップ完了・照合OK: $out/EFI"
  else
    echo "$NG コピー後の照合で差分あり。やり直してください"; return 1
  fi
  shasum -a 256 "$out/EFI/OC/config.plist" | tee "$out/config.plist.sha256" | sed 's/^/  /'
  BACKUP_OUT="$out"
  echo "  復元: このフォルダの EFI を EFI パーティション直下の EFI と置き換える"
  echo
}

# ---------- 5. config.plist の MaxKernel 診断 ----------
pb() { /usr/libexec/PlistBuddy -c "$1" "$2" 2>/dev/null; }

scan_section() { # $1=cfg $2=Kernel セクション名 $3=名前キー  -> "n/total 件が 27 未満上限"
  local cfg="$1" sec="$2" key="$3" i=0 total=0 low=0 en mk nm major
  while :; do
    nm=$(pb "Print :Kernel:$sec:$i:$key" "$cfg") || break
    [ -z "$nm" ] && [ "$i" -gt 0 ] && break
    en=$(pb "Print :Kernel:$sec:$i:Enabled" "$cfg"); mk=$(pb "Print :Kernel:$sec:$i:MaxKernel" "$cfg")
    if [ "$en" = "true" ]; then
      total=$((total+1))
      if [ -n "$mk" ]; then
        major="${mk%%.*}"
        case "$major" in ''|*[!0-9]*) ;; *) if [ "$major" -lt 27 ]; then low=$((low+1)); echo "    x  [$sec] $nm  (MaxKernel $mk)"; fi ;; esac
      fi
    fi
    i=$((i+1)); [ "$i" -gt 400 ] && break
  done
  echo "    -> $sec: 有効 $total 件中 $low 件が MaxKernel 27 未満"
}

do_scan() {
  echo "== config.plist 診断(Liberator #2 の報告と同じ観点) =="
  [ -n "$FOUND_CFG" ] || find_efi || { echo "$NG EFI/OC/config.plist が見つかりません"; return 1; }
  echo "  対象: $FOUND_CFG"
  echo "  (27 のカーネルでは MaxKernel が 25.99.99 / 26.99.99 のものは読み込まれません)"
  scan_section "$FOUND_CFG" Add BundlePath
  scan_section "$FOUND_CFG" Patch Comment
  echo "  Kernel>Block(起動時に除外する kext):"
  local i=0 nm
  while nm=$(pb "Print :Kernel:Block:$i:Identifier" "$FOUND_CFG"); do echo "    - $nm"; i=$((i+1)); [ "$i" -gt 100 ] && break; done
  [ "$i" -eq 0 ] && echo "    (なし)"
  echo "  #2 の報告で必要だったブロック: com.apple.driver.X86PlatformPlugin / com.apple.driver.X86PlatformShim"
  echo "  ※ AMD の Zen+(3300U)に同じ調整が要るかは未確認。起動結果を Issue に書くと有益です。"
  echo
  if [ "$WRITE_PATCHED" -eq 1 ]; then
    [ -n "${BACKUP_OUT:-}" ] || [ -n "$DEST" ] || { echo "$NG バックアップ先が無いので見本を作れません"; return 1; }
    local target="${BACKUP_OUT:-$DEST}/config.plist.mk27" j=0 mk major n=0
    cp "$FOUND_CFG" "$target" || return 1
    while nm=$(pb "Print :Kernel:Patch:$j:Comment" "$target"); do
      mk=$(pb "Print :Kernel:Patch:$j:MaxKernel" "$target"); major="${mk%%.*}"
      case "$major" in ''|*[!0-9]*) ;; *) if [ "$major" -lt 27 ]; then pb "Set :Kernel:Patch:$j:MaxKernel 27.99.99" "$target" >/dev/null; n=$((n+1)); fi ;; esac
      j=$((j+1)); [ "$j" -gt 400 ] && break
    done
    echo "$OK Kernel>Patch の上限を 27.99.99 にした見本を作成($n 件): $target"
    echo "  kext の上限は触っていません。EFI へ入れるかどうかは自分で判断してください。"
    echo
  fi
}

case "$MODE" in
  check)  check_space; check_env; do_scan ;;
  backup) do_backup ;;
  all)    check_space; check_env; do_backup && do_scan ;;
esac
echo "終わり。26 の EFI とデータは変更していません(バックアップ先への書き込みのみ)。"
