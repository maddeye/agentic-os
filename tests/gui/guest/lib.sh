# Helpers shared by the GUI steps. Source this file.
source /opt/aos-tests/tests/integration/guest/lib.sh
guest=/opt/aos-tests/tests/gui/guest
app=$guest/app.py

pixel() { # <png> <x> <y>: prints "R G B"
	ffmpeg -v error -i "$1" -vf "crop=1:1:$2:$3" -f rawvideo -pix_fmt rgb24 - | od -An -tu1 | tr -s ' ' | sed 's/^ //'
}

eventually() { # <name> <expected> <command...>: retries for 10 seconds
	local name=$1 expected=$2 actual="" _
	shift 2
	for _ in $(seq 1 100); do
		actual=$("$@" 2>/dev/null) || true
		[[ "$actual" == "$expected" ]] && break
		sleep 0.1
	done
	eq "$name" "$expected" "$actual"
}

gui() { agentos project gui "$@"; }
state() { # <project> <session>
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$projects/$1/artifacts/gui/$2/metadata.json"
}
