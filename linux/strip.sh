#!/usr/bin/bash

set -e
set -o pipefail
set -u

find . -type f -print0 2>/dev/null | while IFS= read -rd '' file; do
  flag=''
  case "$(riscv64-unknown-linux-gnu-readelf -h "$file" 2>/dev/null)" in
    *Type:*'EXEC (Executable file)'*)
      flag='--strip-all'
      ;;
    *Type:*'DYN (Position-Independent Executable file)'* | *Type:*'DYN (Shared object file)'*)
      flag='--strip-unneeded'
      ;;
    *Type:*'REL (Relocatable file)'*)
      if [[ "$file" = *.ko ]]; then
        flag='--strip-unneeded'
      else
        flag='--strip-debug'
      fi
      ;;
    *)
      continue
      ;;
  esac
  echo "[+] strip: $file ($flag)"
  riscv64-unknown-linux-gnu-strip "$flag" "$file"
done
