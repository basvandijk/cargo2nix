extractFileExt() {
    local name=`basename $1`
    echo ${name##*.}
}
extractHash() {
    local name=`basename $1`
    echo ${name%%-*}
}
makeExternCrateFlags() {
    local i=
    for (( i=1; i<$#; i+=2 )); do
        local extern_name="${@:$i:1}"
        local crate="${@:((i+1)):1}"
        [ -f "$crate/.cargo-info" ] || continue
        local crate_name=`jq -r '.name' $crate/.cargo-info`
        local proc_macro=`jq -r '.proc_macro' $crate/.cargo-info`
        if [ "$proc_macro" ]; then
            echo "--extern" "${extern_name}=$crate/lib/$proc_macro"
        elif [ -f "$crate/lib/lib${crate_name}.rlib" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.rlib"
        elif [ -f "$crate/lib/lib${crate_name}.so" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.so"
        elif [ -f "$crate/lib/lib${crate_name}.a" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.a"
        elif [ -f "$crate/lib/lib${crate_name}.dylib" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.dylib"
        else
            echo >&2 "do not know how to find $extern_name ($crate_name)"
            exit 1
        fi
        echo "-L" dependency=$crate/lib/deps
        if [ -f "$crate/lib/.link-flags" ]; then
            cat $crate/lib/.link-flags
        fi
    done
}
# for cargo doc to work, we need
# 1. --extern foo=foo.rmeta for every dependency
# 2. symlinks to documentation in the target directory
makeExternDocFlags() {
    local i=
    for (( i=1; i<$#; i+=2 )); do
        local extern_name="${@:$i:1}"
        local crate="${@:((i+1)):1}"
        [ -f "$crate/.cargo-info" ] || continue
        local crate_name=`jq -r '.name' $crate/.cargo-info`
        if [ -f "$crate/lib/lib${crate_name}.rmeta" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.rmeta"
        elif [ -f "$crate/lib/lib${crate_name}.dylib" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.dylib"
        elif [ -f "$crate/lib/lib${crate_name}.so" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.so"
        elif [ -f "$crate/lib/lib${crate_name}.rlib" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.rlib"
        fi
    done
}
linkDocs() {
    local docsdir="$1"
    for (( i=2; i<$#; i+=2 )); do
        local extern_name="${@:$i:1}"
        local crate="${@:((i+1)):1}"
        [ -f "$crate/.cargo-info" ] || continue
        local crate_name=`jq -r '.name' $crate/.cargo-info`
        if [ "$crate_name" = "$crateName" ]; then
            debug_print "not linking docs for crate $crate since it has the same name as self"
        elif [ -d "$crate/share/doc/$crate_name" ]; then
            ln -s "$crate/share/doc/$crate_name" "$docsdir"
        else
            debug_print "missing docs for $crate"
        fi
    done
}
loadExternCrateLinkFlags() {
    local i=
    for (( i=1; i<$#; i+=2 )); do
        local extern_name="${@:$i:1}"
        local crate="${@:((i+1)):1}"
        [ -f "$crate/.cargo-info" ] || continue
        local crate_name=`jq -r '.name' $crate/.cargo-info`
        if [ -f "$crate/lib/.link-flags" ]; then
            cat $crate/lib/.link-flags
        fi
    done
}
loadDepKeys() {
    for (( i=2; i<=$#; i+=2 )); do
        local crate="${@:$i:1}"
        [ -f "$crate/.cargo-info" ] && [ -f "$crate/lib/.dep-keys" ] || continue
        cat $crate/lib/.dep-keys
    done
}
linkExternCrateToDeps() {
    local deps_dir=$1; shift
    for (( i=1; i<$#; i+=2 )); do
        local dep="${@:((i+1)):1}"
        [ -f "$dep/.cargo-info" ] || continue
        local crate_name=`jq -r '.name' $dep/.cargo-info`
        local metadata=`jq -r '.metadata' $dep/.cargo-info`
        local proc_macro=`jq -r '.proc_macro' $dep/.cargo-info`
        if [ "$proc_macro" ]; then
            local ext=`extractFileExt $proc_macro`
            ln -sf $dep/lib/$proc_macro $deps_dir/`basename $proc_macro .$ext`-$metadata.$ext
        else
            ln -sf $dep/lib/lib${crate_name}.rlib $deps_dir/lib${crate_name}-${metadata}.rlib
        fi
        (
            shopt -s nullglob
            for subdep in $dep/lib/deps/*; do
                local subdep_name=`basename $subdep`
                ln -sf $subdep $deps_dir/$subdep_name
            done
        )
    done
}
upper() {
    echo ${1^^}
}
dumpDepInfo() {
    local link_flags="$1"; shift
    local dep_keys="$1"; shift
    local cargo_links="$1"; shift
    local dep_files="$1"; shift
    local depinfo="$1"; shift

    cat $depinfo | while read line; do
        [[ "x$line" =~ xcargo:([^=]+)=(.*) ]] || continue
        local key="${BASH_REMATCH[1]}"
        local val="${BASH_REMATCH[2]}"

        case $key in
            rustc-link-lib) ;&
            rustc-flags) ;&
            rustc-cfg) ;&
            rustc-env) ;&
            rerun-if-changed) ;&
            rerun-if-env-changed) ;&
            warning)
            ;;
            rustc-link-search)
                if [[ "$val" = *"$NIX_BUILD_TOP"* ]]; then
                    debug_print "not propagating linker arg '$val'"
                else
                    echo "-L" `printf '%q' $val` >>$link_flags
                fi
                ;;
            *)
                if [ -e "$val" ]; then
                    local dep_file_target=$dep_files/DEP_$(upper $cargo_links)_$(upper $key)
                    cp -r "$val" $dep_file_target
                    val=$dep_file_target
                fi
                printf 'DEP_%s_%s=%s\n' $(upper $cargo_links) $(upper $key) "$val" >>$dep_keys
        esac
    done
}

install_crate() {
    local host_triple=$1
    local mode=$2
    pushd target/${host_triple}/${mode} >/dev/null
    local needs_deps=
    local has_output=
    for output in *; do
        if [ -d "$output" ]; then
            (
                shopt -s nullglob
                rmeta="$(echo $output/*.rmeta)"
                if [ -n "$rmeta" ]; then
                    cp "$rmeta" "$out/lib/lib${crateName}.rmeta"
                fi
            )
        elif [ -x "$output" ]; then
            mkdir -p $out/bin
            cp $output $out/bin/
            has_output=1
        else
            case `extractFileExt "$output"` in
                rlib)
                    mkdir -p $out/lib/.dep-files
                    cp $output $out/lib/
                    local link_flags=$out/lib/.link-flags
                    local dep_keys=$out/lib/.dep-keys
                    touch $link_flags $dep_keys
                    for depinfo in build/*/output; do
                        dumpDepInfo $link_flags $dep_keys "$cargo_links" $out/lib/.dep-files $depinfo
                    done
                    needs_deps=1
                    has_output=1
                    ;;
                a) ;&
                so) ;&
                dylib)
                    mkdir -p $out/lib
                    cp $output $out/lib/
                    has_output=1
                    ;;
                *)
                    continue
            esac
        fi
    done
    popd >/dev/null

    touch $out/lib/.link-flags
    loadExternCrateLinkFlags $dependencies >> $out/lib/.link-flags

    if [ "$isProcMacro" ]; then
        pushd target/${mode} >/dev/null
        for output in *; do
            if [ -d "$output" ]; then
                continue
            fi
            case `extractFileExt "$output"` in
                so) ;&
                dylib)
                    isProcMacro=`basename $output`
                    mkdir -p $out/lib
                    cp $output $out/lib
                    needs_deps=1
                    has_output=1
                    ;;
                *)
                    continue
            esac
        done
        popd >/dev/null
    fi

    if [ ! "$has_output" ]; then
        echo NO OUTPUT IS FOUND
        exit 1
    fi

    if [ "$needs_deps" ]; then
        mkdir -p $out/lib/deps
        linkExternCrateToDeps $out/lib/deps $dependencies
    fi

    echo {} | jq \
'{name:$name, metadata:$metadata, version:$version, proc_macro:$procmacro}' \
--arg name $crateName \
--arg metadata $NIX_RUST_METADATA \
--arg procmacro "$isProcMacro" \
--arg version $version >$out/.cargo-info
}

cargoVerbosityLevel() {
  level=${1:-0}
  verbose_flag=""

  if (( level >= 1 )); then
    verbose_flag="-v"
  elif (( level >= 7 )); then
    verbose_flag="-vv"
  fi

  echo ${verbose_flag}
}
debug_print() {
  if (( $NIX_DEBUG >= 1 )); then
    echo >&2 "$@"
  fi
}
