#!/bin/bash
set -xe
cd "$(dirname "$0")"
source util/vars.sh dl only

if docker info -f "{{println .SecurityOptions}}" | grep rootless >/dev/null 2>&1; then
    UIDARGS=()
else
    UIDARGS=( -u "$(id -u):$(id -g)" )
fi

[[ -t 1 ]] && TTY_ARG="-t" || TTY_ARG=""

DL_SCRIPT_DIR="$(mktemp -d)"
trap "rm -rf -- '$DL_SCRIPT_DIR'" EXIT

mkdir -p "${PWD}"/.cache/downloads

for STAGE in scripts.d/*.sh scripts.d/*/*.sh; do
	STAGENAME="$(basename "$STAGE" | sed 's/.sh$//')"

	cat <<-EOF >"${DL_SCRIPT_DIR}/${STAGENAME}.sh"
		set -xe -o pipefail
		shopt -s dotglob

		source /dl_functions.sh
		source "/$STAGE"
		STG="\$(ffbuild_dockerdl)"

		if [[ -z "\$STG" ]]; then
			exit 0
		fi

		DLHASH="\$(sha256sum <<<"\$STG" | cut -d" " -f1)"
		DLNAME="$STAGENAME"

		if [[ "$1" == "hashonly" ]]; then
			echo "\$DLHASH"
			exit 0
		fi

		TGT="/dldir/\${DLNAME}_\${DLHASH}.tar.xz"
		if [[ -f "\$TGT" ]]; then
			rm -f "/dldir/\${DLNAME}.tar.xz"
			ln -s "\${DLNAME}_\${DLHASH}.tar.xz" "/dldir/\${DLNAME}.tar.xz"
			exit 0
		fi

		# Magpie's mirror (magpie/mirror.json) first, checked against its listed sha256; upstream
		# when the archive is not listed or the mirror fails. An upstream archive is a fresh tarball
		# of a pinned clone, never byte-identical, so only the mirror copy can be checked.
		MIRROR_NAME="\${TGT##*/}"
		MIRROR_SHA="\$(jq -r --arg n "\$MIRROR_NAME" '.archives[\$n] // empty' /mirror.json 2>/dev/null || true)"
		MIRROR_URL="\$(jq -r '.url // empty' /mirror.json 2>/dev/null || true)/\$MIRROR_NAME"
		if [[ -n "\$MIRROR_SHA" ]] && curl -fsSL --retry 3 --connect-timeout 30 --speed-time 60 -o "\$TGT.tmp" "\$MIRROR_URL" &&
			sha256sum -c - <<<"\$MIRROR_SHA  \$TGT.tmp"; then
			echo "mirror: \$MIRROR_NAME from \$MIRROR_URL"
		else
			rm -f "\$TGT.tmp"
			if [[ -n "\$MIRROR_SHA" ]]; then
				echo "mirror: \$MIRROR_NAME failed at \$MIRROR_URL, downloading from upstream"
			else
				echo "mirror: \$MIRROR_NAME is not in magpie/mirror.json, downloading from upstream"
			fi

			WORKDIR="\$(mktemp -d)"
			trap "rm -rf -- '\$WORKDIR'" EXIT
			cd "\$WORKDIR"

			eval "set -e; \$STG"

			tar -I "xz -T0" -cpf "\$TGT.tmp" .
		fi
		mv "\$TGT.tmp" "\$TGT"
		rm -f "/dldir/\${DLNAME}.tar.xz"
		ln -s "\${DLNAME}_\${DLHASH}.tar.xz" "/dldir/\${DLNAME}.tar.xz"
	EOF
done

docker run -i $TTY_ARG --rm "${UIDARGS[@]}" -v "${DL_SCRIPT_DIR}":/stages -v "${PWD}/.cache/downloads":/dldir -v "${PWD}/scripts.d":/scripts.d -v "${PWD}/util/dl_functions.sh":/dl_functions.sh -v "${PWD}/magpie/mirror.json":/mirror.json:ro "${REGISTRY}/${REPO}/base:latest${DOCKER_TAG_SUFFIX:-}" \
	bash -c 'set -xe && for STAGE in /stages/*.sh; do bash $STAGE; done'
