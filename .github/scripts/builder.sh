#!/usr/bin/env bash
## <DO NOT RUN STANDALONE, meant for CI Only>
## Meant to Install AM Apps & Sync to HF
## Self: https://raw.githubusercontent.com/pkgforge-community/AM-HF-SYNC/refs/heads/main/.github/scripts/builder.sh
# bash <(curl -qfsSL "https://raw.githubusercontent.com/pkgforge-community/AM-HF-SYNC/refs/heads/main/.github/scripts/builder.sh")
#-------------------------------------------------------#

#-------------------------------------------------------#
##Version
AMB_VERSION="0.0.7" && echo -e "[+] AM Builder Version: ${AMB_VERSION}" ; unset AMB_VERSION
##Enable Debug 
 if [[ "${DEBUG}" = "1" ]] || [[ "${DEBUG}" = "ON" ]]; then
    set -x
 fi
#-------------------------------------------------------#

#-------------------------------------------------------#
##Sanity
export TZ="UTC"
#GH
 if [[ "${GHA_MODE}" != "MATRIX" ]]; then
   echo -e "[-] FATAL: This Script only Works on Github Actions\n"
  exit 1
 fi
#Input
 if [[ -z "${AM_PKG_NAME+x}" ]]; then
   echo -e "[-] FATAL: Package Name '\${AM_PKG_NAME}' is NOT Set\n"
  exit 1
 else
   export AM_PKG_NAME="${AM_PKG_NAME}"
 fi
#Host
 if [[ -z "${HOST_TRIPLET+x}" ]]; then
  HOST_TRIPLET="$(uname -m)-$(uname -s)"
  HOST_TRIPLET_L="${HOST_TRIPLET,,}"
  export HOST_TRIPLET HOST_TRIPLET_L
 fi
#Script
 if [[ "${HOST_TRIPLET}" == "aarch64-Linux" ]]; then
   BUILD_SCRIPT="https://github.com/ivan-hc/AM/blob/main/programs/aarch64/${AM_PKG_NAME}"
 elif [[ "${HOST_TRIPLET}" == "x86_64-Linux" ]]; then
   BUILD_SCRIPT="https://github.com/ivan-hc/AM/blob/main/programs/x86_64/${AM_PKG_NAME}"
 fi
 BUILD_SCRIPT_RAW="$(echo "${BUILD_SCRIPT}" | sed 's|/blob/main|/raw/main|' | tr -d '[:space:]')"
#Tmp
 if [[ ! -d "${SYSTMP}" ]]; then
  SYSTMP="$(dirname $(mktemp -u))" && export SYSTMP
 fi
#User-Agent
 if [[ -z "${USER_AGENT+x}" ]]; then
  USER_AGENT="$(curl -qfsSL 'https://pub.ajam.dev/repos/Azathothas/Wordlists/Misc/User-Agents/ua_chrome_macos_latest.txt')"
 fi
#Path
 export PATH="${HOME}/bin:${HOME}/.cargo/bin:${HOME}/.cargo/env:${HOME}/.go/bin:${HOME}/go/bin:${HOME}/.local/bin:${HOME}/miniconda3/bin:${HOME}/miniconda3/condabin:/usr/local/zig:/usr/local/zig/lib:/usr/local/zig/lib/include:/usr/local/musl/bin:/usr/local/musl/lib:/usr/local/musl/include:${PATH}"
 PATH="$(echo "${PATH}" | awk 'BEGIN{RS=":";ORS=":"}{gsub(/\n/,"");if(!a[$0]++)print}' | sed 's/:*$//')" ; export PATH
#Cleanup 
 unset GH_TOKEN GITHUB_TOKEN HF_TOKEN
#-------------------------------------------------------#

#-------------------------------------------------------#
##Main
pushd "$(mktemp -d)" &>/dev/null && \
  BUILD_DIR="$(realpath .)" && \
  git clone --depth="1" --filter="blob:none" --no-checkout "https://huggingface.co/datasets/pkgforge/AMcache" && \
  cd "./AMcache" && HF_REPO_DIR="$(realpath .)"
  if [[ ! -d "${HF_REPO_DIR}" ]]; then
     echo -e "\n[-] FATAL: Failed to create \${HF_REPO_DIR}"
    exit 1
  fi
  #LFS
   git lfs install &>/dev/null ; huggingface-cli lfs-enable-largefiles "." &>/dev/null
  #Setup Branch
   setup_hf_pkgbranch()
   {
    HF_PKGBRANCH="$(echo "${AM_PKG_NAME}/${HOST_TRIPLET}/${PKG_VERSION}" | sed 's/[^a-zA-Z0-9\/_-]//g' | tr -d '[:space:]')"
    HF_PKGBRANCH_ESC="$(echo "${HF_PKGBRANCH}" | tr -d '[:space:]' | sed 's/[^a-zA-Z0-9]/_/g' | tr -d '[:space:]')"
    HF_PKGBRANCH_URI="$(echo "${HF_PKGBRANCH}" | tr -d '[:space:]' | jq -sRr '@uri' | tr -d '[:space:]')"
    echo -e "[+] Remote (Branch): ${HF_PKGBRANCH}"
    echo -e "[+] Remote (URL): https://huggingface.co/datasets/pkgforge/AMcache/tree/${HF_PKGBRANCH_URI}"
    git -C "${HF_REPO_DIR}" checkout -b "${HF_PKGBRANCH}" || git checkout "${HF_PKGBRANCH}"
    if [[ "$(git -C "${HF_REPO_DIR}" rev-parse --abbrev-ref HEAD | sed -e '/^[[:space:]]*$/d;1q' | tr -d '[:space:]')" != "${HF_PKGBRANCH}" ]]; then
       echo -e "\n[-] FATAL: Failed to switch to ${HF_PKGBRANCH}\n"
      return 1
    else
      git -C "${HF_REPO_DIR}" fetch origin "${HF_PKGBRANCH}" 2>/dev/null
      echo HF_PKGBRANCH="${HF_PKGBRANCH}" >> "${GITHUB_ENV}"
      echo HF_PKGBRANCH_ESC="${HF_PKGBRANCH_ESC}" >> "${GITHUB_ENV}"
      echo HF_PKGBRANCH_URI="${HF_PKGBRANCH_URI}" >> "${GITHUB_ENV}"
    fi
   }
   export -f setup_hf_pkgbranch
  #Git Attributes
   fix_gitattributes()
    {
     if [[ -n "${HF_PKGBRANCH+x}" ]] && [[ -n "${HF_PKGBRANCH##*[[:space:]]}" ]]; then
      pushd "$(mktemp -d)" &>/dev/null && \
       git clone --branch "${HF_PKGBRANCH}" --depth="1" --filter="blob:none" --no-checkout \
        "https://huggingface.co/datasets/pkgforge/AMcache" "./TEMPREPO" &>/dev/null &&\
         cd "./TEMPREPO" && git checkout "${HF_PKGBRANCH}"
       if [[ "$(git rev-parse --abbrev-ref HEAD | sed -e '/^[[:space:]]*$/d;1q' | tr -d '[:space:]')" == "${HF_PKGBRANCH}" ]]; then
        git rm --cached --ignore-unmatch '.gitattributes'
        git sparse-checkout init --cone
        git sparse-checkout set ".gitattributes"
        git lfs uninstall 2>/dev/null
        git lfs untrack '.gitattributes' 2>/dev/null
        #git checkout HEAD^ -- '.gitattributes'
        #git restore --staged --worktree "."
        echo '*/* filter=lfs diff=lfs merge=lfs -text' > "./.gitattributes"
        echo '* filter=lfs diff=lfs merge=lfs -text' >> "./.gitattributes"
        sed '/^[[:space:]]*[^*]/d' -i "./.gitattributes"
        git add --all --renormalize --verbose
        git commit -m "Init (GitAttributes)"
        git push -u origin "${HF_PKGBRANCH}"
       fi
      [[ -d "$(realpath .)/TEMPREPO" ]] && rm -rf "$(realpath .)" &>/dev/null && popd &>/dev/null
     fi
    }
   export -f fix_gitattributes
  #Checkout
   checkout_sparse()
   {
    pushd "${HF_REPO_DIR}" &>/dev/null &&\
     git sparse-checkout set "" ; git sparse-checkout set --no-cone --sparse-index ".gitattributes" ; git sparse-checkout list
    popd &>/dev/null
   }
   export -f checkout_sparse
  #Install
   readarray -d '' -t "AM_DIRS_PRE" < <(find "/opt" -maxdepth 1 -type d -print0 2>/dev/null)
   TEMP_LOG="${BUILD_DIR}/${AM_PKG_NAME}.log.tmp" && touch "${TEMP_LOG}"
   LOGPATH="${BUILD_DIR}/${AM_PKG_NAME}.log"
   {
     echo -e "\n[+] Installing ${AM_PKG_NAME} <== ${BUILD_SCRIPT} ["$(date --utc '+%Y-%m-%dT%H:%M:%S')" UTC]\n"
     timeout -k 5s 10s curl -w "\n(Script) <== %{url}\n" -qfsSL "${BUILD_SCRIPT_RAW}"
     set -x
     timeout -k 10s 300s am install --debug "${AM_PKG_NAME}"
     timeout -k 10s 300s am files "${AM_PKG_NAME}" | cat -
     timeout -k 10s 300s am about "${AM_PKG_NAME}" | cat -
   } 2>&1 | ts -s '[%H:%M:%S]➜ ' | tee "${TEMP_LOG}"
  #logs
   sanitize_logs()
   {
   if [[ -s "${TEMP_LOG}" && $(stat -c%s "${TEMP_LOG}") -gt 10 && -n "${LOGPATH}" ]]; then
    echo -e "\n[+] Sanitizing $(realpath "${TEMP_LOG}") ==> ${LOGPATH}"
    if command -v trufflehog &> /dev/null; then
      trufflehog filesystem "${TEMP_LOG}" --no-fail --no-verification --no-update --json 2>/dev/null | jq -r '.Raw' | sed '/{/d' | xargs -I "{}" sh -c 'echo "{}" | tr -d " \t\r\f\v"' | xargs -I "{}" sed "s/{}/ /g" -i "${TEMP_LOG}"
    fi
    sed -e '/.*github_pat.*/Id' \
       -e '/.*ghp_.*/Id' \
       -e '/.*glpat.*/Id' \
       -e '/.*hf_.*/Id' \
       -e '/.*token.*/Id' \
       -e '/.*AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.*/Id' \
       -e '/.*access_key_id.*/Id' \
       -e '/.*secret_access_key.*/Id' \
       -e '/.*cloudflarestorage.*/Id' -i "${TEMP_LOG}"
    sed '/\(LOGPATH\|ENVPATH\)=/d' -i "${TEMP_LOG}"
       echo '\\\\================= Package Forge [External] ================////' > "${LOGPATH}"
       echo '|--- Repository: https://github.com/ivan-hc/AM                 ---|' >> "${LOGPATH}"
       echo '|--- Web/Search Index: https://portable-linux-apps.github.io/  ---|' >> "${LOGPATH}"
       echo '|--- Contact: https://github.com/ivan-hc                       ---|' >> "${LOGPATH}"
       echo '|--- Discord: https://discord.gg/djJUs48Zbu                    ---|' >> "${LOGPATH}"    
       echo '|--- Docs: https://docs.pkgforge.dev/repositories/external/am  ---|' >> "${LOGPATH}"
       echo '|--- Bugs/Issues: https://github.com/ivan-hc/AM/issues         ---|' >> "${LOGPATH}"
       echo '|-----------------------------------------------------------------|' >> "${LOGPATH}"
       grep -viE 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|github_pat|ghp_|glpat|hf_|token|access_key_id|secret_access_key|cloudflarestorage' "${TEMP_LOG}" >> "${LOGPATH}" && rm "${TEMP_LOG}" 2>/dev/null
   fi
   }
   export -f sanitize_logs
   if command -v ansi2txt &>/dev/null; then
     sanitize_logs
     cat "${LOGPATH}" | ansi2txt > "${LOGPATH}.tmp" && \
     mv -fv "${LOGPATH}.tmp" "${LOGPATH}"
   else
     sanitize_logs
   fi
   readarray -d '' -t "AM_DIRS_POST" < <(find "/opt" -maxdepth 1 -type d -print0 2>/dev/null)
  #Type
   get_pkg_type()
   {
     if [[ -s "${LOGPATH}" && $(stat -c%s "${LOGPATH}") -gt 10 ]]; then
       if grep -m1 -qi "appimage" "${LOGPATH}"; then
         PKG_TYPE="appimage"
       elif grep -m1 -qi "dynamic-binary" "${LOGPATH}"; then
         PKG_TYPE="dynamic"
       elif grep -m1 -qi "static-binary" "${LOGPATH}"; then
         PKG_TYPE="static"
       fi
       export PKG_TYPE
       echo "PKG_TYPE=${PKG_TYPE}" >> "${GITHUB_ENV}"
     fi
   }
   export -f get_pkg_type
  #Check
   AM_DIR_PKG="$(comm -13 <(printf "%s\n" "${AM_DIRS_PRE[@]}" | sort) <(printf "%s\n" "${AM_DIRS_POST[@]}" | sort) | awk -F'/' '!seen[$2 "/" $3]++ {print "/opt/" $3}' | sed -e '/^[[:space:]]*$/d;1q' | tr -d '[:space:]')"
   if [[ -d "${AM_DIR_PKG}" ]] && [[ "$(du -s "${AM_DIR_PKG}" | cut -f1)" -gt 100 ]]; then
    #Get PKG_Type
     get_pkg_type
     if [[ "${PKG_TYPE}" == "appimage" ]]; then
      #Lowercase
       find "${AM_DIR_PKG}" -maxdepth 1 -type f -exec bash -c 'for f; do file -i "$f" | grep -Ei "application/.*executable" >/dev/null && mv -fv "$f" "$(dirname "$f")/$(basename "$f" | tr [:upper:] [:lower:])" 2>/dev/null; done' bash "{}" +
      #Store Pkg Names
       readarray -t "AM_PKG_NAMES" < <(find "${AM_DIR_PKG}" -maxdepth 1 -type f -exec file -i "{}" \; | grep -Ei 'application/.*executable' | cut -d":" -f1 | xargs realpath | xargs -I "{}" basename "{}" | sort -u | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
     else
       readarray -t "AM_PKG_NAMES" < <(echo "${AM_PKG_NAME}")
       if [[ -d "${AM_DIR_PKG}/${AM_PKG_NAME}" ]]; then
         [[ ! -f "${AM_DIR_PKG}/${AM_PKG_NAME}/${AM_PKG_NAME}" ]] && echo "_${AM_PKG_NAME}_" > "${AM_DIR_PKG}/${AM_PKG_NAME}/${AM_PKG_NAME}"
       elif [[ ! -f "${AM_DIR_PKG}/${AM_PKG_NAME}" ]]; then
         echo "_${AM_PKG_NAME}_" > "${AM_DIR_PKG}/${AM_PKG_NAME}"
       fi
     fi
    #Sanity Check 
     if [[ "${#AM_PKG_NAMES[@]}" -eq 0 ]]; then
       echo -e "\n[-] FATAL: Failed to Find any Progs [${AM_DIR_PKG}]\n"
       echo "GHA_BUILD_FAILED=YES" >> "${GITHUB_ENV}"
       echo "BUILD_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
       find "${AM_DIR_PKG}" -maxdepth 1 -type f -exec file -i "{}" \;
     else
       echo -e "[+] Progs: ${AM_PKG_NAMES[*]}"
     fi
   else
     echo -e "\n[-] FATAL: Failed to Build ${AM_PKG_NAME}\n"
     echo "GHA_BUILD_FAILED=YES" >> "${GITHUB_ENV}"
     echo "BUILD_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
     ls "/opt" -lah
   fi
  #For each Prog
   for PKG_NAME in "${AM_PKG_NAMES[@]}"; do
     unset BUILD_SUCCESSFUL COMMIT_MSG DESKTOP_FILE HF_PKGBRANCH ICON_FILE ICON_TYPE PKG_BSUM PKG_BUILD_DATE PKG_BUILD_GHA PKG_BUILD_ID PKG_BUILD_LOG PKG_BUILD_SCRIPT PKG_DATETMP PKG_DESCRIPTION PKG_DESCRIPTION_TMP PKG_DESKTOP PKG_DOWNLOAD_URL _PKG_DOWNLOAD_URL PKG_HOMEPAGE PKG_ICON PKG_SHASUM PKG_SIZE PKG_SIZE_RAW PKG_SRC_URL PKG_TYPE PKG_VERSION
     echo "PUSH_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
     if [[ -f "${AM_DIR_PKG}/${PKG_NAME}" ]] && [[ $(stat -c%s "${AM_DIR_PKG}/${PKG_NAME}") -gt 5 ]]; then
       echo "BUILD_SUCCESSFUL=YES" >> "${GITHUB_ENV}"
       #Prep
        pushd "${HF_REPO_DIR}" &>/dev/null && \
         #Dynamic --> Static
          if file "${AM_DIR_PKG}/${PKG_NAME}" | grep -m1 -qi "dynamic"; then
             echo -e "\n[+] ${PKG_NAME} (Dynamic) ==> ${PKG_NAME} (Static)\n"
             timeout -k 10s 300s bash -c 'yes "y" | am nolibfuse "${AM_PKG_NAME}" | cat -' &>/dev/null || true
          fi
         #Version
          PKG_VERSION="$(sed -n 's/.*version *: *\([^ ]*\).*/\1/p' "${LOGPATH}" | tr -d '[:space:]')"
          if [ -z "${PKG_VERSION+x}" ] || [ -z "${PKG_VERSION##*[[:space:]]}" ]; then
            if grep -qi "github.com" "${AM_DIR_PKG}/version"; then
              PKG_VERSION="$(sed -E 's#.*/download/([^/]+)/.*#\1#' "${AM_DIR_PKG}/version" | tr -d '[:space:]')"
            else
              PKG_VERSION="latest"
            fi
          fi
         #Dir
          if [[ -d "${HF_REPO_DIR}" ]]; then
            fix_gitattributes ; sleep 5
            pushd "${HF_REPO_DIR}" &>/dev/null
            checkout_sparse ; sleep 3
            setup_hf_pkgbranch ; sleep 1
          else
            echo -e "\n[-] FATAL: Failed to create \${HF_REPO_DIR}\n"
            echo "GHA_BUILD_FAILED=YES" >> "${GITHUB_ENV}"
            echo "BUILD_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
           continue
          fi
         #Pkg
          cp -fv "${AM_DIR_PKG}/${PKG_NAME}" "${HF_REPO_DIR}/${PKG_NAME}"
          if [[ -f "${HF_REPO_DIR}/${PKG_NAME}" ]] && [[ $(stat -c%s "${HF_REPO_DIR}/${PKG_NAME}") -gt 5 ]]; then
           PKG_NAME="${PKG_NAME}"
           echo -e "[+] Name: ${PKG_NAME} ('.pkg_name')"
           PKG_DOWNLOAD_URL="https://huggingface.co/datasets/pkgforge/AMcache/resolve/${HF_PKGBRANCH_URI}/${PKG_NAME}"
           echo -e "[+] Download URL: ${PKG_DOWNLOAD_URL} ('.download_url')"
           get_pkg_type
           echo -e "[+] Type: ${PKG_TYPE} ('.pkg_type')"
          fi
         #Info
          timeout -k 10s 300s am about "${AM_PKG_NAME}" 2>/dev/null | cat -> "${HF_REPO_DIR}/${PKG_NAME}.txt"
         #Build Date
          PKG_DATETMP="$(date --utc '+%Y-%m-%dT%H:%M:%S')Z"
          PKG_BUILD_DATE="$(echo "${PKG_DATETMP}" | sed 's/ZZ\+/Z/Ig')"
          echo -e "[+] Build Date: ${PKG_BUILD_DATE} ('.build_date')"
         #Build GH
          PKG_BUILD_GHA="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
          PKG_BUILD_ID="${GITHUB_RUN_ID}"
         #Build Log
          cp -fv "${LOGPATH}" "${HF_REPO_DIR}/${PKG_NAME}.log"
          if [[ -f "${HF_REPO_DIR}/${PKG_NAME}.log" ]] && [[ $(stat -c%s "${HF_REPO_DIR}/${PKG_NAME}.log") -gt 5 ]]; then
           PKG_BUILD_LOG="https://huggingface.co/datasets/pkgforge/AMcache/resolve/${HF_PKGBRANCH_URI}/${PKG_NAME}.log"
           echo -e "[+] Build Log: ${PKG_BUILD_LOG} ('.build_log')"
          fi
         #Build Script
          curl -qfsSL "${BUILD_SCRIPT_RAW}" -o "${HF_REPO_DIR}/AM_SCRIPT"
          if [[ -f "${HF_REPO_DIR}/AM_SCRIPT" ]] && [[ $(stat -c%s "${HF_REPO_DIR}/AM_SCRIPT") -gt 5 ]]; then
           PKG_BUILD_SCRIPT="${BUILD_SCRIPT}"
           #PKG_BUILD_SCRIPT="https://huggingface.co/datasets/pkgforge/AMcache/resolve/${HF_PKGBRANCH_URI}/AM_SCRIPT"
           echo -e "[+] Build Script: ${PKG_BUILD_SCRIPT} ('.build_script')"
          fi
         #Checksums
          PKG_BSUM="$(b3sum "${HF_REPO_DIR}/${PKG_NAME}" | grep -oE '^[a-f0-9]{64}' | tr -d '[:space:]')"
          echo -e "[+] B3SUM: ${PKG_BSUM} ('.bsum')"
          PKG_SHASUM="$(sha256sum "${HF_REPO_DIR}/${PKG_NAME}" | grep -oE '^[a-f0-9]{64}' | tr -d '[:space:]')"
          echo -e "[+] SHA256SUM: ${PKG_SHASUM} ('.shasum')"
         #Description
          if [[ -z "${PKG_DESCRIPTION+x}" ]] || [[ -z "${PKG_DESCRIPTION##*[[:space:]]}" ]]; then
            PKG_DESCRIPTION="$(awk 'BEGIN {IGNORECASE=1}
               /version:/ {f=1; next}
               /site:/ {f=0}
               f {sub(/.*]➜[[:space:]]*/, ""); sub(/^[[:space:].]+/, ""); sub(/[[:space:].]+$/, ""); if (NF) print}' "${HF_REPO_DIR}/${PKG_NAME}.log" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sed -e '/^[[:space:]]*$/d;1q')"
          fi
          PKG_DESCRIPTION_TMP="${PKG_DESCRIPTION}"
          PKG_DESCRIPTION="$(echo "${PKG_DESCRIPTION_TMP}" | sed 's/`//g' | sed 's/^[ \t]*//;s/[ \t]*$//' | sed ':a;N;$!ba;s/\r\n//g; s/\n//g' | sed 's/["'\'']//g' | sed 's/|//g' | sed 's/`//g')"
          echo -e "[+] Description: ${PKG_DESCRIPTION} ('.description')"
         #Desktop
          DESKTOP_FILE="$(find '/usr/local/share/applications/' -type f -iname "*AM*desktop" -print | sort -u | sed -e '/^[[:space:]]*$/d;1q' | tr -d '[:space:]')"
          if [[ -f "${DESKTOP_FILE}" ]] && [[ $(stat -c%s "${DESKTOP_FILE}") -gt 5 ]]; then
           cp -fv "${DESKTOP_FILE}" "${HF_REPO_DIR}/${PKG_NAME}.desktop"
           if [[ -f "${HF_REPO_DIR}/${PKG_NAME}.desktop" ]] && [[ $(stat -c%s "${HF_REPO_DIR}/${PKG_NAME}.desktop") -gt 5 ]]; then
             sed '/.*DBusActivatable.*/I d' -i "${HF_REPO_DIR}/${PKG_NAME}.desktop"
             sed -E 's/\s+setup\s+/ /Ig' -i "${HF_REPO_DIR}/${PKG_NAME}.desktop"
             sed "s/Icon=[^ ]*/Icon=${PKG}/" -i "${HF_REPO_DIR}/${PKG_NAME}.desktop"
             PKG_DESKTOP="https://huggingface.co/datasets/pkgforge/AMcache/resolve/${HF_PKGBRANCH_URI}/${PKG_NAME}.desktop"
             echo -e "[+] Desktop: ${PKG_DESKTOP} ('.desktop')"
           fi
          fi
          find "${HF_REPO_DIR}" -maxdepth 1 -type f -iname "*.desktop" -exec sed -E 's/^[[:space:]]*[Ee]xec[[:space:]]*=[[:space:]]*[^[:space:]]+/Exec={{pkg_path}}/' -i "{}" \;
         #Homepage
          PKG_HOMEPAGE="$(grep -o 'http[s]\?://[^"]*' "${HF_REPO_DIR}/${PKG_NAME}.txt" | tr -d '"' | grep -iv "github.com" | sed -e '/^[[:space:]]*$/d;1q' | tr -d '[:space:]')"
          PKG_HOMEPAGE_GH="$(grep -o 'http[s]\?://[^"]*' "${HF_REPO_DIR}/${PKG_NAME}.txt" | tr -d '"' | grep -i "github.com" | sed -e '/^[[:space:]]*$/d;1q' | tr -d '[:space:]')"
          if echo "${PKG_HOMEPAGE_GH}" | grep -qi 'http'; then
            PKG_HOMEPAGE="${PKG_HOMEPAGE_GH}"
            PKG_SRC_URL="${PKG_HOMEPAGE_GH}"
          elif echo "${PKG_HOMEPAGE}" | grep -qE 'http'; then
            PKG_HOMEPAGE="${PKG_HOMEPAGE}"
            PKG_SRC_URL="${PKG_HOMEPAGE}"
          else
            PKG_HOMEPAGE=""
            PKG_SRC_URL=""
          fi
          echo -e "[+] Homepage: ${PKG_HOMEPAGE} ('.homepage')"
         #Icon
          ICON_FILE="$(find "${AM_DIR_PKG}/icons" -type f -exec stat --format="%s %n" "{}" + | sort -nr | sed -e '/^[[:space:]]*$/d;1q' | sed 's/^[0-9]\+[[:space:]]\+//')"
          if [[ -f "${ICON_FILE}" ]] && [[ $(stat -c%s "${ICON_FILE}") -gt 5 ]]; then
            ICON_TYPE="$(file -i "${ICON_FILE}")"
             if echo "${ICON_TYPE}" | grep -qiE 'image/(png)'; then
               cp -fv "${ICON_FILE}" "${HF_REPO_DIR}/${PKG_NAME}.png"
               if [[ -f "${HF_REPO_DIR}/${PKG_NAME}.png" ]] && [[ $(stat -c%s "${HF_REPO_DIR}/${PKG_NAME}.png") -gt 5 ]]; then
                 PKG_ICON="https://huggingface.co/datasets/pkgforge/AMcache/resolve/${HF_PKGBRANCH_URI}/${PKG_NAME}.png"
               fi
             elif echo "${ICON_TYPE}" | grep -qiE 'image/(svg)'; then
               cp -fv "${ICON_FILE}" "${HF_REPO_DIR}/${PKG_NAME}.svg"
               if [[ -f "${HF_REPO_DIR}/${PKG_NAME}.svg" ]] && [[ $(stat -c%s "${HF_REPO_DIR}/${PKG_NAME}.svg") -gt 5 ]]; then
                 PKG_ICON="https://huggingface.co/datasets/pkgforge/AMcache/resolve/${HF_PKGBRANCH_URI}/${PKG_NAME}.svg"
               fi
             elif echo "${ICON_TYPE}" | grep -qE 'image/(jpeg|jpg)'; then
               cp -fv "${ICON_FILE}" "${HF_REPO_DIR}/${PKG_NAME}.jpg"
               if [[ -f "${HF_REPO_DIR}/${PKG_NAME}.jpg" ]] && [[ $(stat -c%s "${HF_REPO_DIR}/${PKG_NAME}.jpg") -gt 5 ]]; then
                 PKG_ICON="https://huggingface.co/datasets/pkgforge/AMcache/resolve/${HF_PKGBRANCH_URI}/${PKG_NAME}.jpg"
               fi
             fi
           echo -e "[+] Icon: ${PKG_ICON} ('.icon')"
          fi
         #Size
          PKG_SIZE_RAW="$(stat --format="%s" "${HF_REPO_DIR}/${PKG_NAME}" | tr -d '[:space:]')"
          PKG_SIZE="$(du -sh "${HF_REPO_DIR}/${PKG_NAME}" | awk '{unit=substr($1,length($1)); sub(/[BKMGT]$/,"",$1); print $1 " " unit "B"}')"
          echo -e "[+] Size: ${PKG_SIZE} ('.size')"
          echo -e "[+] Size (Raw): ${PKG_SIZE_RAW} ('.size_raw')"
      #Generate PKG_ID
       if [[ "${PKG_TYPE}" == "appimage" ]]; then
         export AM_PKG_ID="AM.$(uname -m).${AM_PKG_NAME}.${PKG_NAME}"
       else
         export PKG_TYPE="archive"
         export AM_PKG_ID="AM.$(uname -m).${AM_PKG_NAME}.${PKG_NAME}.bundle.tar"
       fi
      #Generate Bundle
       if echo "${AM_PKG_ID}" | grep -qi "bundle\.tar$"; then
         #Copy Struct
          rsync -achv "${AM_DIR_PKG}/." "${HF_REPO_DIR}/_bundle"
         #Copy Symlinks
          find "/usr/local/bin" -type l -exec bash -c 'for f do 
            t=$(readlink "${f}")
            if [[ $t == /opt/* && $t != /opt/am/* ]]; then
              if [[ -e "${t}" ]]; then
                echo "Processing ${f} -> ${t}"
                dest_dir="$(dirname "${t}")"
                sym_name="$(basename "${f}" | tr [:upper:] [:lower:])"
                target_file="$(basename "${t}")"
                if mkdir -p "${dest_dir}/SOAR_SYMS"; then
                  orig_dir="$(pwd)"
                  if cd "${dest_dir}/SOAR_SYMS"; then
                    if ln -fs "../$target_file" "${sym_name}"; then
                      echo "Created: ${dest_dir}/SOAR_SYMS/${sym_name} --> ../$target_file"
                      echo "Resolved: $(readlink -f "$(realpath ${dest_dir}/SOAR_SYMS/${sym_name})")"
                      if [[ -e "${sym_name}" ]]; then
                        echo "Verified: Symlink points to existing file"
                      else
                        echo "WARNING: Created symlink appears to be broken: ${dest_dir}/SOAR_SYMS/${sym_name}"
                      fi
                    else
                      echo "ERROR: Failed to create symlink ${sym_name} in ${dest_dir}/SOAR_SYMS"
                    fi
                    cd "$orig_dir" || exit 1
                  else
                    echo "ERROR: Could not change to directory ${dest_dir}/SOAR_SYMS"
                  fi
                else
                  echo "ERROR: Could not create directory ${dest_dir}/SOAR_SYMS"
                fi
              else
                echo "SKIPPING: Target does not exist: $t"
              fi
            fi
          done' _ {} \;
          realpath "${AM_DIR_PKG}/SOAR_SYMS" && ls -lah "${AM_DIR_PKG}/SOAR_SYMS"
         #Relocate Symlinks          
          if [[ -d "${AM_DIR_PKG}/SOAR_SYMS" ]] && [[ -n "$(find "${AM_DIR_PKG}/SOAR_SYMS" -type l -print -quit)" ]]; then
            cp -frv "${AM_DIR_PKG}/SOAR_SYMS" "${HF_REPO_DIR}/_bundle"
          else
             echo -e "[-] FATAL: Failed to relocate Symlink\n"
            exit 1
          fi
         #Prepare Dir
          sudo chown -R "$(whoami):$(whoami)" "${HF_REPO_DIR}/_bundle" && chmod -R 755 "${HF_REPO_DIR}/_bundle"
          tree "${HF_REPO_DIR}/_bundle" -L 2 2>/dev/null
          tree "${HF_REPO_DIR}/_bundle" 2>/dev/null
         #Pack Dir
          pushd "$(mktemp -d)" &>/dev/null && \
           tar --directory="${HF_REPO_DIR}/_bundle" --verbose --preserve-permissions --create --file="bundle.tar" "."
          pushd "${HF_REPO_DIR}" &>/dev/null
         #Check
          if [[ -f "./bundle.tar" ]] && [[ $(stat -c%s "./bundle.tar") -gt 1024 ]]; then
             mv -fv "./bundle.tar" "${HF_REPO_DIR}/${PKG_NAME}.bundle.tar" &&\
             rm -rf "${HF_REPO_DIR}/_bundle"
          else
             echo -e "[-] FATAL: Failed to create Bundle\n"
            exit 1
          fi
         #Fix Metadata
          if [[ -f "${HF_REPO_DIR}/${PKG_NAME}.bundle.tar" ]] && [[ $(stat -c%s "${HF_REPO_DIR}/${PKG_NAME}.bundle.tar") -gt 1024 ]]; then
           echo "\n[+] (Re) Fixing Metadata\n"
            _PKG_DOWNLOAD_URL="${PKG_DOWNLOAD_URL}.bundle.tar"
            export PKG_DOWNLOAD_URL="${_PKG_DOWNLOAD_URL}"
            PKG_BSUM="$(b3sum "${HF_REPO_DIR}/${PKG_NAME}.bundle.tar" | grep -oE '^[a-f0-9]{64}' | tr -d '[:space:]')"
            echo -e "[+] B3SUM: ${PKG_BSUM} ('.bsum')"
            PKG_SHASUM="$(sha256sum "${HF_REPO_DIR}/${PKG_NAME}.bundle.tar" | grep -oE '^[a-f0-9]{64}' | tr -d '[:space:]')"
            echo -e "[+] SHA256SUM: ${PKG_SHASUM} ('.shasum')"
            PKG_SIZE_RAW="$(stat --format="%s" "${HF_REPO_DIR}/${PKG_NAME}.bundle.tar" | tr -d '[:space:]')"
            PKG_SIZE="$(du -sh "${HF_REPO_DIR}/${PKG_NAME}.bundle.tar" | awk '{unit=substr($1,length($1)); sub(/[BKMGT]$/,"",$1); print $1 " " unit "B"}')"
            echo -e "[+] Size: ${PKG_SIZE} ('.size')"
            echo -e "[+] Size (Raw): ${PKG_SIZE_RAW} ('.size_raw')"
          fi
       fi
      #Generate Json
       jq -n --arg HOST "${HOST_TRIPLET}" \
         --arg PKG "${AM_PKG_NAME}" \
         --arg PKG_ID "${AM_PKG_ID}" \
         --arg PKG_NAME "${PKG_NAME,,}" \
         --arg PKG_TYPE "${PKG_TYPE}" \
         --arg BSUM "${PKG_BSUM}" \
         --arg BUILD_DATE "${PKG_BUILD_DATE}" \
         --arg BUILD_GHA "${PKG_BUILD_GHA}" \
         --arg BUILD_ID "${PKG_BUILD_ID}" \
         --arg BUILD_LOG "${PKG_BUILD_LOG}" \
         --arg BUILD_SCRIPT "${PKG_BUILD_SCRIPT}" \
         --arg DESCRIPTION "${PKG_DESCRIPTION}" \
         --arg DESKTOP "${PKG_DESKTOP}" \
         --arg DOWNLOAD_URL "${PKG_DOWNLOAD_URL}" \
         --arg HOMEPAGE "${PKG_HOMEPAGE}" \
         --arg ICON "${PKG_ICON}" \
         --arg PROVIDES "$(printf "%s\n" "${AM_PKG_NAMES[@]}" | paste -sd, - | tr -d '[:space:]')" \
         --arg SHASUM "${PKG_SHASUM}" \
         --arg SIZE "${PKG_SIZE}" \
         --arg SIZE_RAW "${PKG_SIZE_RAW}" \
         --arg SRC_URL "${PKG_SRC_URL}" \
         --arg VERSION "${PKG_VERSION}" \
         '
          {
            _disabled: ("false"),
            host: $HOST,
            pkg: $PKG,
            pkg_id: $PKG_ID,
            pkg_name: $PKG_NAME,
            pkg_type: $PKG_TYPE,
            bsum: $BSUM,
            build_date: $BUILD_DATE,
            build_gha: $BUILD_GHA,
            build_id: $BUILD_ID,
            build_log: $BUILD_LOG,
            build_script: $BUILD_SCRIPT,
            description: (
             if ($DESCRIPTION != "") 
             then $DESCRIPTION | gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | gsub("^\\s+|\\s+$"; "") | gsub("^\\.+|\\.+$"; "") 
             else "No description available"
             end
            ),
            desktop: $DESKTOP,
            download_url: $DOWNLOAD_URL,
            homepage: [$HOMEPAGE],
            icon: $ICON,
            maintainer: [
            "AM (https://github.com/ivan-hc/AM)"
            ],
            note: [
            "[EXTERNAL] We CAN NOT guarantee the authenticity, validity or security",
            "This package was auto-built, cached & uploaded using AM",
            "Provided by: https://github.com/ivan-hc/AM",
            "Learn More: https://docs.pkgforge.dev/repositories/external/am",
            "Please create an Issue or send a PR for an official Package"
            ],
            provides: ($PROVIDES | split(",")),
            shasum: $SHASUM,
            size: $SIZE,
            size_raw: $SIZE_RAW,
            src_url: [$SRC_URL],
            version: (
             if ($VERSION != "")
             then $VERSION 
             else "latest"
             end
             )
          }
         ' | jq 'walk(if type == "object" then with_entries(select(.value != null and .value != "")) | select(length > 0) elif type == "array" then map(select(. != null and . != "")) | select(length > 0) else . end)' > "${BUILD_DIR}/${PKG_NAME}.json"
      #Copy Json
       if jq -r '.pkg_name' "${BUILD_DIR}/${PKG_NAME}.json" | grep -iv 'null' | tr -d '[:space:]' | grep -Eiq "^${PKG_NAME}$"; then
         cp -fv "${BUILD_DIR}/${PKG_NAME}.json" "${HF_REPO_DIR}/${PKG_NAME}.json"
         cp -fv "${HF_REPO_DIR}/${PKG_NAME}.json" "${METADATA_DIR}/${HF_PKGBRANCH_ESC}-${PKG_NAME}.json"
         echo -e "\n[+] JSON <==> ${HF_PKGBRANCH}\n"
         jq . "${HF_REPO_DIR}/${PKG_NAME}.json"
       else
         echo -e "\n[-] FATAL: JSON Generation Likely Failed <==> ${HF_PKGBRANCH}\n"
         jq . "${BUILD_DIR}/${PKG_NAME}.json" || cat "${BUILD_DIR}/${PKG_NAME}.json"
       fi
      #Sync
       pushd "${HF_REPO_DIR}" &>/dev/null && \
         git remote -v
         COMMIT_MSG="[+] PKG [${HF_PKGBRANCH}] (${PKG_TYPE:-${PKG_VERSION}})"
         git pull origin "${HF_PKGBRANCH}"
         git pull origin "${HF_PKGBRANCH}" --ff-only || git pull --rebase origin "${HF_PKGBRANCH}"
         git merge --no-ff -m "Merge & Sync" 2>/dev/null
         git lfs track './**/*' 2>/dev/null
         git lfs untrack '.gitattributes' 2>/dev/null
         sed '/\*/!d' -i '.gitattributes'
         if [[ -d "${HF_REPO_DIR}" ]] && [[ "$(du -s "${HF_REPO_DIR}" | cut -f1)" -gt 100 ]]; then
           find "${HF_REPO_DIR}" -type f -size -3c -delete
           git sparse-checkout add "**"
           git sparse-checkout list
           find "." -maxdepth 1 -type f -not -path "*/\.*" | xargs -I "{}" git add "{}" --verbose
           git add --all --renormalize --verbose
           git commit -m "${COMMIT_MSG}"
           retry_git_push()
           {
            for i in {1..10}; do
             #Generic Merge
              git pull origin "${HF_PKGBRANCH}" --ff-only
              git merge --no-ff -m "${COMMIT_MSG}"
             #Push
              git pull origin "${HF_PKGBRANCH}" 2>/dev/null
              if git push -u origin "${HF_PKGBRANCH}"; then
                 echo "PUSH_SUCCESSFUL=YES" >> "${GITHUB_ENV}"
                 break
              fi
             #Sleep randomly 
              sleep "$(shuf -i 500-4500 -n 1)e-3"
            done
           }
           export -f retry_git_push
           retry_git_push
           git --no-pager log '-1' --pretty="format:'%h - %ar - %s - %an'"
           if ! git ls-remote --heads origin | grep -qi "$(git rev-parse HEAD)"; then
            echo -e "\n[-] WARN: Failed to push ==> ${HF_PKGBRANCH}/${PKG_VERSION}\n(Retrying ...)\n"
            retry_git_push
            git --no-pager log '-1' --pretty="format:'%h - %ar - %s - %an'"
            if ! git ls-remote --heads origin | grep -qi "$(git rev-parse HEAD)"; then
              echo -e "\n[-] FATAL: Failed to push ==> ${HF_PKGBRANCH}/${PKG_VERSION}\n"
               echo -e "\n[+] Trying Force Push ...\n"
               git push -u origin "${HF_PKGBRANCH}" --force
               if ! git ls-remote --heads origin | grep -qi "$(git rev-parse HEAD)"; then
                 if [[ -n "${GITHUB_TEST_BUILD+x}" ]]; then
                    rm -rf "${HF_REPO_DIR}/.git" 2>/dev/null
                    echo -e "\n[+] Trying with HuggingFace CLI ...\n"
                    huggingface-cli upload "pkgforge/AMcache" "${HF_REPO_DIR}" --repo-type "dataset" --revision "${HF_PKGBRANCH}" --commit-message "${COMMIT_MSG}"
                 fi
               else
                  echo -e "\n[+] Force Pushed ==> ${HF_PKGBRANCH}/${PKG_VERSION}\n"
                  echo "PUSH_SUCCESSFUL=YES" >> "${GITHUB_ENV}"
               fi
            fi
           fi
           du -sh "${HF_REPO_DIR}" && realpath "${HF_REPO_DIR}"
         else
           echo -e "\n[-] FATAL: Failed to Build ==> ${AM_PKG_NAME}\n"
           echo "GHA_BUILD_FAILED=YES" >> "${GITHUB_ENV}"
           echo "BUILD_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
           echo "PUSH_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
         fi
       pushd "${TMPDIR}" &>/dev/null
     else
       echo -e "\n[-] FATAL: Failed to Find ${PKG_NAME} [${AM_DIR_PKG}]\n"
       get_pkg_type
       echo "GHA_BUILD_FAILED=YES" >> "${GITHUB_ENV}"
       echo "BUILD_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
       echo "PUSH_SUCCESSFUL=NO" >> "${GITHUB_ENV}"
     fi
   done
##Cleanup
popd &>/dev/null
#-------------------------------------------------------#

#-------------------------------------------------------#
#Cleanup Dir  
 if [[ -n "${GITHUB_TEST_BUILD+x}" ]]; then
  rm -rf "${HF_REPO_DIR}/.git" 2>/dev/null
  7z a -t7z -mx="9" -mmt="$(($(nproc)+1))" -bsp1 -bt "/tmp/BUILD_ARTIFACTS.7z" "${HF_REPO_DIR}/${AM_PKG_NAME}" 2>/dev/null
 elif [[ "${KEEP_LOGS}" != "YES" ]]; then
  echo -e "\n[-] Removing ALL Logs & Files\n"
  rm -rvf "${BUILD_DIR}" 2>/dev/null
 fi
##Disable Debug 
 if [ "${DEBUG}" = "1" ] || [ "${DEBUG}" = "ON" ]; then
    set +x
 fi
#-------------------------------------------------------#