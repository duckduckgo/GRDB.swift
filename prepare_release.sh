#!/bin/bash

set -e

mute=">/dev/null 2>&1"
if [[ "$1" == "-v" ]]; then
	mute=
fi

cwd="$(dirname "${BASH_SOURCE[0]}")"
workdir="$(mktemp -d)"
mkdir -p "${workdir}/Logs"
# trap 'rm -rf "$workdir"' EXIT
grdb_dir="${workdir}/GRDB-source"
sqlcipher_dir="${workdir}/sqlcipher-source"

print_usage_and_exit() {
	cat <<- EOF
	Usage:
	  $ $(basename "$0") [-v] [-h] [<grdb_tag>]

	Options:
	 -h      Show this message
	 -v      Verbose output
	EOF

	exit 1
}

read_command_line_arguments() {
	while getopts 'hv' OPTION; do
		case "${OPTION}" in
			h)
				print_usage_and_exit
				;;
			v)
				mute=
				;;
			*)
				;;
		esac
	done

	shift $((OPTIND-1))

	grdb_tag="$1"
	if [[ -n "$grdb_tag" ]]; then
		force_release=1
	fi
}

clone_grdb() {
	if ! [[ -d "$grdb_dir" ]]; then
		rm -rf "$grdb_dir"

		printf '%s' "Cloning upstream GRDB.swift ... "
		eval git clone https://github.com/groue/GRDB.swift.git "$grdb_dir" "$mute"
		echo "✅"
	fi

	cd "${grdb_dir}"
	grdb_tag="${1:-$(git describe --tags --abbrev=0)}"
	eval git checkout "${grdb_tag}" "$mute"
	cd -
	echo "Checked out GRDB.swift latest tag: $grdb_tag"
}

clone_sqlcipher() {
	printf '%s' "Cloning SQLCipher ... "
	eval git clone https://github.com/sqlcipher/sqlcipher.git "$sqlcipher_dir" "$mute"
	echo "✅"

	export GIT_DIR="${sqlcipher_dir}/.git"
	sqlcipher_tag="${SQLCIPHER_VERSION:-$(git describe --tags --abbrev=0)}"
	eval git checkout "$(git describe --tags --abbrev=0)" "$mute"
	unset GIT_DIR
	echo "Checked out SQLCipher latest tag: $sqlcipher_tag"
}

update_readme() {
	current_version="$(git describe --tags --abbrev=0 --exclude=v* main)"
	current_upstream_version="$(grep '\* GRDB' README.md | cut -d '*' -f 3)"
	current_sqlcipher_version="$(grep '\* SQLCipher' README.md | cut -d '*' -f 3)"

	export new_version upstream_version="${grdb_tag#v}" sqlcipher_version="${sqlcipher_tag#v}"

	if [[ "${current_upstream_version}" == "${upstream_version}" ]] && \
		[[ "${current_sqlcipher_version}" == "${sqlcipher_version}" ]] && \
		[[ -z "$force_release" ]]; then
		echo "GRDB.swift (${upstream_version}) and SQLCipher (${sqlcipher_version}) versions did not change. Skipping release."
		exit 1
	fi

	cat <<- EOF

	DuckDuckGo GRDB.swift current version: ${current_version}
	Upstream GRDB.swift version: ${current_upstream_version} -> ${upstream_version}
	SQLCipher version: ${current_sqlcipher_version} -> ${sqlcipher_version}
	EOF

	while ! [[ "${new_version}" =~ [0-9]\.[0-9]\.[0-9] ]]; do
		read -rp "Input DuckDuckGo GRDB.swift desired version number (x.y.z): " new_version < /dev/tty
	done

	envsubst < "${cwd}/assets/README.md.in" > README.md

	echo "Updated README.md ✅"
	echo ""
}

build_sqlcipher() {
	local sqlcipher_destdir="${grdb_dir}/GRDB"
	local header_path="${sqlcipher_destdir}/sqlite3.h"
	local impl_path="${sqlcipher_destdir}/sqlite3.c"

	eval pushd "$sqlcipher_dir" "$mute" || { echo "pushd failed"; exit 1; }

	printf '%s' "Configuring SQLCipher ... "
	eval ./configure "$mute"
	echo "✅"

	printf '%s' "Building SQLCipher ... "
	ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo "1")
	eval make -j"${ncpu}" sqlite3.c "$mute"
	echo "✅"

	eval popd "$mute" || { echo "popd failed"; exit 1; }

	printf '%s' "Moving SQLCipher artifacts into place ... "
	rm -f "$header_path" "$impl_path"
	mkdir -p "${sqlcipher_destdir}/include"
	cp -f "${sqlcipher_dir}/sqlite3.h" "$header_path"

	# Including param.h unconditionally removes compile time
	# warnings about ambiguous MIN and MAX macros.
	echo "#include <sys/param.h>" > "$impl_path"
	cat "${sqlcipher_dir}/sqlite3.c" >> "${impl_path}"
	echo "✅"
}

patch_grdb() {
	local patch_file="${cwd}/assets/xcodeproj.patch"
	local grdb_xcodeproj_file="${grdb_dir}/GRDB.xcodeproj"

	printf '%s' "Patching GRDB ... "
	: > "${grdb_dir}/GRDB/Export.swift"
	echo "#include \"${grdb_dir}/SQLCipher.xcconfig\"" >> "${grdb_dir}/Support/GRDBDeploymentTarget.xcconfig"
	find "$grdb_dir" . -name "*.swift" -type f -exec sed -i '' 's/import SQLCipher/\/\/ import SQLCipher/g' {} +

	if patch -s -p1 -f -d "$grdb_dir" < "$patch_file"; then
		echo "✅"
	else
		echo "❌"
		cat <<-EOF
		Failed to automatically patch GRDB.swift Xcode project file. Please follow instructions for manual patching:
			1. After you confirm reading instructions, two windows will open:
				* Xcode, with GRDB.swift project
				* Finder, with GRDB source code directory (look for sqlite3.h and sqlite3.c files)
			2. Drag sqlite3.h and sqlite3.c to the Xcode project under GRDB directory. Add both files to GRDB target.
			3. Select sqlite3.h in Xcode, open right hand side panel and adjust Target Membership by marking the header file as Public.
			4. Close Xcode project, go back to terminal and press Ctrl+C to continue.
		EOF

		read -n 1 -srp "Press any key to continue"
		open "${grdb_dir}/GRDB"
		open "$grdb_xcodeproj_file"

		echo ""
		echo "Make edits to the project file, close it and press Ctrl+C when you're ready"
		read -rp "Press enter to continue"

		pushd "$grdb_dir" >/dev/null 2>&1
		local diff
		diff=$(git diff "GRDB.xcodeproj/project.pbxproj")
		popd >/dev/null 2>&1
		echo "$diff" > "${patch_file}"
		echo "Updated Xcode project patch file ✅"
	fi
}

setup_log_formatter() {
	if command -v xcbeautify &> /dev/null; then
		log_formatter='xcbeautify'
	elif command -v xcpretty &> /dev/null; then
		log_formatter='xcpretty'
	else
		echo
		echo "xcbeautify and xcpretty not found - not prettifying Xcode logs. You can install xcbeautify using 'brew install xcbeautify'."
		echo
		log_formatter='tee'
	fi
}

build_and_test_release() {
	local derived_data_dir="${grdb_dir}/DerivedData"
	local log_file="${workdir}/Logs/GRDB-${grdb_tag}-unittests.log"

	setup_log_formatter
	rm -rf "${derived_data_dir}"
	cp -f "${cwd}/assets/SQLCipher.xcconfig" "${grdb_dir}"

	printf '%s' "Building GRDB ... "
	if xcodebuild build-for-testing \
		-project "${grdb_dir}/GRDB.xcodeproj" \
		-scheme "GRDB" \
		-derivedDataPath "$derived_data_dir" >"$log_file" 2>&1; then

		echo "✅"
	else
		echo "❌"
		echo "Failed to build GRDB with SQLCipher support. See log file at ${log_file} for more info."
		exit 1
	fi

	echo "Testing GRDB ... ⚙️"
	# The skipped test references a test database added with a podfile.
	# We're safe to disable it since we don't care about SQLCipher 3 compatibility anyway.
	if xcodebuild test-without-building \
		-project "${grdb_dir}/GRDB.xcodeproj" \
		-scheme "GRDB" \
		-derivedDataPath "$derived_data_dir" \
		-skip-testing:GRDBTests/EncryptionTests/testSQLCipher3Compatibility \
		| tee -a "$log_file" | $log_formatter 2>&1; then

		echo "Unit tests succeeded ✅"
	else
		cat <<-EOF
		Unit tests failed ❌
		See log file at ${log_file} for more info.
		Rerun with -f to skip testing.
		EOF
		exit 1
	fi
}

build_archive() {
	local platform=$1
	local archives_path=$2
	local log_file="${workdir}/Logs/GRDB-archive-${platform/ /-}.log"

	printf '%s' "  * Archiving for ${platform} ... "

	if xcodebuild archive \
		-project "${grdb_dir}/GRDB.xcodeproj" \
		-scheme GRDB \
		-destination "generic/platform=${platform}" \
		-archivePath "${archives_path}/GRDB-${platform}" \
		-derivedDataPath "${derived_data}" \
		"${build_opts[@]}" >"$log_file" 2>&1; then

		echo "✅"
	else
		echo "❌"
		echo "Failed to create archive. See log file at ${log_file} for more info."
		exit 1
	fi
}

build_xcframework() {
	local derived_data="${workdir}/DerivedData"
	local xcframework="${workdir}/GRDB.xcframework"
	xcframework_zip="${workdir}/GRDB.xcframework.zip"
	local archives_dir="archives"
	local archives_path="${workdir}/${archives_dir}"

	build_opts=("BUILD_LIBRARY_FOR_DISTRIBUTION=YES" "SKIP_INSTALL=NO" "ONLY_ACTIVE_ARCH=NO")

	echo ""
	echo "Building XCFramework ⚙️"

	rm -rf "${derived_data}" "${archives_path}" "${xcframework}"

	build_archive "iOS" "$archives_path"
	build_archive "iOS Simulator" "$archives_path"
	build_archive "macOS" "$archives_path"
	build_archive "macOS,variant=Mac Catalyst" "$archives_path"

	printf '%s' "Creating XCFramework ... "
	pushd "$workdir" >/dev/null 2>&1
	xcodebuild -create-xcframework \
 		-archive "${archives_dir}/GRDB-iOS.xcarchive" -framework GRDB.framework \
		-archive "${archives_dir}/GRDB-iOS Simulator.xcarchive" -framework GRDB.framework \
		-archive "${archives_dir}/GRDB-macOS.xcarchive" -framework GRDB.framework \
		-archive "${archives_dir}/GRDB-macOS,variant=Mac Catalyst.xcarchive" -framework GRDB.framework \
		-output "${xcframework}" >/dev/null 2>&1
	popd >/dev/null 2>&1
	echo "✅"
	
	printf '%s' "Compressing XCFramework ... "
	rm -rf "$xcframework_zip"
	ditto -c -k --keepParent "$xcframework" "$xcframework_zip"
	echo "✅"
}

update_swift_package() {
	printf '%s' "Updating Package.swift ... "
	export checksum
	checksum=$(swift package compute-checksum "$xcframework_zip")
	envsubst < "${cwd}/assets/Package.swift.in" > "${cwd}/Package.swift"
	echo "✅"
}

make_release() {
	echo "Making ${new_version} release ... 🚢"

	local commit_message="DuckDuckGo GRDB.swift ${new_version} (GRDB ${upstream_version}, SQLCipher ${sqlcipher_version})"

	git add "${cwd}/README.md" "${cwd}/Package.swift" "${cwd}/assets/xcodeproj.patch"
	git commit -m "$commit_message"
	git tag -m "$commit_message" "$new_version"
	git push origin main
	git push origin "$new_version"

	gh release create "$new_version" --generate-notes "${xcframework_zip}" --repo duckduckgo/GRDB.swift

	cat <<- EOF

	🎉 Release is ready at https://github.com/duckduckgo/GRDB.swift/releases/tag/${new_version}
	EOF
}

main() {
	printf '%s\n' "Using directory at ${workdir}"

	read_command_line_arguments "$@"

	clone_grdb "$grdb_tag"
	clone_sqlcipher
	update_readme
	build_sqlcipher
	patch_grdb
	build_and_test_release
	build_xcframework
	update_swift_package
	make_release
}

main "$@"
