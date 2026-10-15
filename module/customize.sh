ui_print " "
ui_print "======================================="
ui_print "               NoMount                 "
ui_print "  Native Kernel Injection Metamodule   "
ui_print "======================================="
ui_print " "

ui_print "- Device Architecture: $ARCH"

# KernelSU reports x86_64 devices as "x64", Magisk as "x86_64"
ARCH_BIN="$ARCH"
[ "$ARCH_BIN" = "x64" ] && ARCH_BIN="x86_64"

# Check root implementation
if [ "$KSU" = "true" ] || command -v ksud >/dev/null 2>&1 || [ -x /data/adb/ksu/bin/ksud ]; then
  ROOT_IMP=ksu
  ui_print "- Root implementation: KernelSU"
elif [ "$APATCH" = "true" ] || command -v apd >/dev/null 2>&1 || [ -x /data/adb/ap/bin/apd ]; then
  ROOT_IMP=ap
  ui_print "- Root implementation: APatch"
else
  abort "! Unsupported root env"
fi

if [ ! -f "$MODPATH/bin/nm-$ARCH_BIN" ]; then
  abort "! Unsupported architecture: $ARCH"
fi
mv "$MODPATH/bin/nm-$ARCH_BIN" "$MODPATH/bin/nm"
set_perm "$MODPATH/bin/nm" 0 0 0755

mkdir -p "/data/adb/$ROOT_IMP/bin"
if ln -sf "/data/adb/modules/nomount/bin/nm" "/data/adb/$ROOT_IMP/bin/nm"; then
  ui_print "- Symlink created."
else
  ui_print "! Failed to create 'nm' symlink, skipping.."
fi

mv "$MODPATH/bin/lkmloader-$ARCH_BIN" "$MODPATH/lkm/lkmloader"
set_perm "$MODPATH/lkm/lkmloader" 0 0 0755
rm -rf "$MODPATH"/bin/nm-* "$MODPATH"/bin/lkmloader-*

try_load_ko() {
  local output

  output=$("$MODPATH/lkm/lkmloader" "$1" 2>&1)
  if "$MODPATH/bin/nm" version >/dev/null 2>&1; then
    return 0
  fi

  if echo "$output" | grep -qi "File exists"; then
    return 0
  fi

  ui_print "  $output"
  return 1
}

OLD_MODPATH="/data/adb/modules/nomount"
KVER=$(uname -r | cut -d'.' -f1,2)
AKVER=$(uname -r | grep -oE 'android[0-9]+')
ARCH_SFX=""
[ "$ARCH_BIN" = "x86_64" ] && ARCH_SFX="-x86_64"

if [ -n "$AKVER" ]; then
  ui_print "- Detected Kernel: $KVER ($AKVER branch)"
else
  ui_print "- Detected Kernel: $KVER (Custom/Unknown branch)"
fi

API_RESPONDS=false
LKM_RUNNING=false
BUILTIN=false
STAGED_FOR_REBOOT=false
LOADED_FRESH=false

ui_print "- Checking kernel support via internal API..."
if "$MODPATH/bin/nm" version >/dev/null 2>&1; then
  API_RESPONDS=true
elif [ -x "$OLD_MODPATH/bin/nm" ] && "$OLD_MODPATH/bin/nm" version >/dev/null 2>&1; then
  API_RESPONDS=true
fi

if [ "$API_RESPONDS" = true ]; then
  if grep -q '^nomount ' /proc/modules; then
    LKM_RUNNING=true
  else
    BUILTIN=true
  fi
fi

if [ "$BUILTIN" = true ]; then
  ui_print "  [OK] NoMount is built into the kernel."
  rm -rf "$MODPATH/lkm"

elif [ "$LKM_RUNNING" = true ]; then
  ui_print "  [*] Active LKM detected."
  ui_print "  [*] Verifying new driver (no unload)..."

  EXACT="$MODPATH/lkm/nomount-${AKVER}-${KVER}${ARCH_SFX}.ko"
  CANDIDATE=""

  if [ -n "$AKVER" ] && [ -f "$EXACT" ]; then
    CANDIDATE="$EXACT"
  else
    for mod in "$MODPATH"/lkm/nomount*-${KVER}${ARCH_SFX}.ko; do
      [ -f "$mod" ] || continue
      CANDIDATE="$mod"
      break
    done
  fi

  if [ -n "$CANDIDATE" ]; then
    ui_print "  [*] Testing candidate: ${CANDIDATE##*/}"
    if try_load_ko "$CANDIDATE"; then
      mv "$CANDIDATE" "$MODPATH/lkm/nomount.ko"
      STAGED_FOR_REBOOT=true
      ui_print "  [+] New driver verified and staged for the next reboot."
    else
      ui_print "  [!] New driver failed verification; keeping the running one."
      if [ -f "$OLD_MODPATH/lkm/nomount.ko" ]; then
        mkdir -p "$MODPATH/lkm"
        cp "$OLD_MODPATH/lkm/nomount.ko" "$MODPATH/lkm/nomount.ko"
        cp "$OLD_MODPATH/bin/nm" "$MODPATH/bin/nm" 2>/dev/null && set_perm "$MODPATH/bin/nm" 0 0 0755
      fi
    fi
  else
    ui_print "  [*] No new KO shipped; keeping the running driver as is."
  fi

  rm -f "$MODPATH"/lkm/nomount-*.ko

else
  ui_print "  [*] Built-in support not found. Attempting LKM injection..."

  EXACT="$MODPATH/lkm/nomount-${AKVER}-${KVER}${ARCH_SFX}.ko"
  CANDIDATE=""

  if [ -n "$AKVER" ] && [ -f "$EXACT" ]; then
    CANDIDATE="$EXACT"
  else
    for mod in "$MODPATH"/lkm/nomount*-${KVER}${ARCH_SFX}.ko; do
      [ -f "$mod" ] || continue
      CANDIDATE="$mod"
      break
    done
  fi

  if [ -n "$CANDIDATE" ]; then
    ui_print "  [*] Trying: ${CANDIDATE##*/}"
    if try_load_ko "$CANDIDATE"; then
      mv "$CANDIDATE" "$MODPATH/lkm/nomount.ko"
      LOADED_FRESH=true
    fi
  fi

  if [ "$LOADED_FRESH" = false ] && [ -f "$OLD_MODPATH/lkm/nomount.ko" ]; then
    ui_print "  [!] New driver failed; restoring previous working LKM..."
    mkdir -p "$MODPATH/lkm"
    cp "$OLD_MODPATH/lkm/nomount.ko" "$MODPATH/lkm/nomount.ko"
    cp "$OLD_MODPATH/bin/nm" "$MODPATH/bin/nm" 2>/dev/null && set_perm "$MODPATH/bin/nm" 0 0 0755
    if try_load_ko "$MODPATH/lkm/nomount.ko"; then
      LOADED_FRESH=true
    fi
  fi

  rm -f "$MODPATH"/lkm/nomount-*.ko

  if [ "$LOADED_FRESH" = false ]; then
    ui_print " "
    ui_print "***************************************************"
    ui_print "* [!] WARNING: KERNEL DRIVER NOT DETECTED         *"
    ui_print "***************************************************"
    ui_print "* NoMount Internal API missing/unresponsive and   *"
    ui_print "* no compatible loadable kernel module was found. *"
    ui_print "*                                                 *"
    ui_print "* This module will NOT FUNCTION until you flash   *"
    ui_print "* a Kernel compiled with CONFIG_NOMOUNT=y         *"
    ui_print "***************************************************"
    ui_print " "
    abort "! Kernel module not detected"
  fi
fi

if [ "$STAGED_FOR_REBOOT" = true ]; then
  ui_print "  [OK] Update staged. Reboot to activate the new driver."
  ui_print "       The running driver keeps working until then."
else
  ui_print "  [OK] System is ready for injection."
fi

NOMOUNT_DATA="/data/adb/nomount"
mkdir -p "$NOMOUNT_DATA"
rm -f "$NOMOUNT_DATA/.booting"

ui_print "- Installation complete."
