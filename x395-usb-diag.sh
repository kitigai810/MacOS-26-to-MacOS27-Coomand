#!/bin/bash
# x395-usb-diag.sh — macOS 26 で「USB が全く認識されない」原因を調べる(読み取り専用)
#
#   bash x395-usb-diag.sh
#
# 調べること: USB コントローラ(XHCI)の有無 / 読み込まれている USB 系 kext /
#             OpenCore の USB マッピング kext・XhciPortLimit・USB 関連 SSDT / 各 MaxKernel
# 結果は ~/Desktop/usb-diag-日時.txt にも保存します(そのファイルの中身を貼ればOK)。
# 触るのは EFI の一時マウントだけ(終了時に自動でアンマウント)。何も書き換えません。

set -u
[ "$(uname)" = "Darwin" ] || { echo "macOS 上で実行してください。"; exit 1; }

OUT="$HOME/Desktop/usb-diag-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

MOUNTED_BY_US=""
cleanup() { for d in $MOUNTED_BY_US; do diskutil unmount "$d" >/dev/null 2>&1; done; }
trap cleanup EXIT

pb() { /usr/libexec/PlistBuddy -c "$1" "$2" 2>/dev/null; }
verdict=""
add_v() { verdict="$verdict
  - $1"; }

echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))  $(date)"
echo

# ---------- 1. macOS が見ている USB ----------
echo "== 1. macOS が認識している USB =="
USBDEV=$(ioreg -p IOUSB -w0 2>/dev/null | grep -c "+-o")
echo "  IOUSB 上のデバイス数(ルートハブ含む): $USBDEV"
ioreg -p IOUSB -w0 2>/dev/null | grep "+-o" | sed 's/^/    /' | head -20
SP=$(system_profiler SPUSBDataType 2>/dev/null | grep -c -E "Product ID|Vendor ID")
echo "  system_profiler のUSBデバイス数: $SP"
echo

# ---------- 2. PCI 上の XHCI コントローラ ----------
echo "== 2. PCI 上の USB コントローラ(class 0c03) =="
XHCI_PCI=$(ioreg -r -c IOPCIDevice -l -w0 2>/dev/null | grep -c -E '"class-code" = <[0-9a-f]{2}0[0-9a-f]030c00>|"class-code" = <..03.c00>|"class-code" = <30030c00>')
echo "  コントローラ数: $XHCI_PCI"
ioreg -r -c IOPCIDevice -l -w0 2>/dev/null | grep -E '"IORegistryEntryName"|"class-code"' | grep -B1 -E "030c00" | grep IORegistryEntryName | sed 's/^/    /' | head
XHCI_DRV=$(ioreg -l -w0 2>/dev/null | grep -c -E "AppleUSBXHCI|AppleUSBHostController")
echo "  ドライバ(AppleUSBXHCI系)の登録数: $XHCI_DRV"
echo

# ---------- 3. 読み込まれている kext ----------
echo "== 3. 読み込まれている USB 系 kext =="
LOADED=$(kmutil showloaded 2>/dev/null | grep -i -E "usb|xhci|utb")
if [ -n "$LOADED" ]; then echo "$LOADED" | awk '{print "    " $0}' | cut -c1-140 | head -30
else echo "    (USB 系 kext の読み込みなし)"; fi
echo "  起動引数: $(sysctl -n kern.bootargs 2>/dev/null)"
echo

# ---------- 4. OpenCore の設定 ----------
echo "== 4. OpenCore の USB 設定 =="
CFG=""
for d in $(diskutil list 2>/dev/null | awk '/ EFI EFI /{print $NF}'); do
  mp=$(diskutil info "/dev/$d" 2>/dev/null | awk -F: '/Mount Point/{sub(/^ +/,"",$2);print $2}')
  if [ -z "$mp" ]; then
    echo "  /dev/$d をマウントします(sudo のパスワードを聞かれます)"
    sudo diskutil mount "/dev/$d" >/dev/null 2>&1 || continue
    MOUNTED_BY_US="$MOUNTED_BY_US /dev/$d"
    mp=$(diskutil info "/dev/$d" 2>/dev/null | awk -F: '/Mount Point/{sub(/^ +/,"",$2);print $2}')
  fi
  [ -f "$mp/EFI/OC/config.plist" ] && { CFG="$mp/EFI/OC/config.plist"; KDIR="$mp/EFI/OC/Kexts"; ADIR="$mp/EFI/OC/ACPI"; break; }
done

if [ -z "$CFG" ]; then
  echo "  [ NG ] EFI/OC/config.plist が見つかりません"
else
  echo "  config: $CFG"
  echo "  OpenCore: $(pb 'Print :Misc:Debug:Target' "$CFG" >/dev/null; strings "$(dirname "$CFG")/OpenCore.efi" 2>/dev/null | grep -m1 -E '^[0-9]\.[0-9]\.[0-9]$' || echo '?')"
  echo
  echo "  -- Kexts フォルダの USB 関連 --"
  ls "$KDIR" 2>/dev/null | grep -i -E "usb|utb|xhc|map|port" | sed 's/^/    /' || true
  echo
  echo "  -- config.plist の Kernel>Add(USB 関連) --"
  i=0; USBKEXT=0; UTB=0; MAPKEXT=0
  while bp=$(pb "Print :Kernel:Add:$i:BundlePath" "$CFG"); do
    case "$bp" in *[Uu][Ss][Bb]*|*UTB*|*XHC*|*[Mm]ap*)
      en=$(pb "Print :Kernel:Add:$i:Enabled" "$CFG"); mk=$(pb "Print :Kernel:Add:$i:MaxKernel" "$CFG"); mn=$(pb "Print :Kernel:Add:$i:MinKernel" "$CFG")
      echo "    $bp  Enabled=$en  Min=${mn:-なし}  Max=${mk:-なし}"
      USBKEXT=$((USBKEXT+1))
      case "$bp" in *USBToolBox*) UTB=1; [ "$en" = "true" ] || add_v "USBToolBox.kext が無効(Enabled=false)です" ;; esac
      case "$bp" in *UTBMap*|*USBMap*|*UTBDefault*) MAPKEXT=1; [ "$en" = "true" ] || add_v "$bp が無効(Enabled=false)です" ;; esac
      if [ "$en" = "true" ] && [ -n "$mk" ]; then
        major="${mk%%.*}"; case "$major" in ''|*[!0-9]*) ;; *) [ "$major" -lt 25 ] && add_v "$bp の MaxKernel=$mk は macOS 26 (Darwin 25) より低く、26 では読み込まれません" ;; esac
      fi ;;
    esac
    i=$((i+1)); [ "$i" -gt 300 ] && break
  done
  [ "$USBKEXT" -eq 0 ] && echo "    (USB 系の kext エントリなし)"
  echo
  echo "  -- Kernel>Quirks --"
  for q in XhciPortLimit; do echo "    $q = $(pb "Print :Kernel:Quirks:$q" "$CFG" || echo '?')"; done
  echo "  -- ACPI>Add(USB / XHC / RHUB 系 SSDT) --"
  j=0; ACPIUSB=0
  while pth=$(pb "Print :ACPI:Add:$j:Path" "$CFG"); do
    case "$pth" in *[Uu][Ss][Bb]*|*UIAC*|*XHC*|*RHUB*|*UTB*) echo "    $pth  Enabled=$(pb "Print :ACPI:Add:$j:Enabled" "$CFG")"; ACPIUSB=$((ACPIUSB+1)) ;; esac
    j=$((j+1)); [ "$j" -gt 300 ] && break
  done
  [ "$ACPIUSB" -eq 0 ] && echo "    (USB 系 SSDT なし)"
  echo

  [ "$UTB" -eq 0 ] && [ "$MAPKEXT" -eq 0 ] && add_v "USBToolBox / UTBMap / USBMap のマッピング kext が設定にありません。ポートが一つも出ない原因の第一候補です"
  [ "$UTB" -eq 1 ] && [ "$MAPKEXT" -eq 0 ] && add_v "USBToolBox.kext はあるが、マップ(UTBMap.kext)がありません"
  [ "$UTB" -eq 0 ] && [ "$MAPKEXT" -eq 1 ] && add_v "UTBMap はあるが、本体の USBToolBox.kext がありません(UTBMap 単体では動きません)"
fi

# ---------- 5. 判定 ----------
echo "== 5. 判定(目安) =="
[ "${USBDEV:-0}" -le 1 ] && [ "${SP:-0}" -eq 0 ] && add_v "macOS が USB デバイスを1つも見ていません。内蔵カメラ等も出ないなら、コントローラが動いていません"
[ "${XHCI_PCI:-0}" -eq 0 ] && add_v "PCI 上に USB コントローラ(class 0c03)が見つかりません。ioreg の取り方が合わない可能性もあるので、報告で出力を確認させてください"
[ "${XHCI_PCI:-0}" -gt 0 ] && [ "${XHCI_DRV:-0}" -eq 0 ] && add_v "コントローラはあるがドライバが付いていません。USB 系 kext か ACPI 設定を疑います"
if [ -z "$verdict" ]; then echo "  明らかな欠落は見つかりませんでした。出力全体を貼ってください。"
else echo "  気になる点:$verdict"; fi
echo
echo "保存先: $OUT"
echo "(EFI と設定は何も書き換えていません)"
