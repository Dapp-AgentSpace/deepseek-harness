#!/usr/bin/env bash
# harness-stack.sh — 技术栈/构建探测深模块。scaffold（接线 gates.*）与 gate（执行门禁）共用同一份
# 「仓库形状」知识，消除探测谓词/优先级/maxdepth 在两处的漂移。
# source 后使用（本文件是库，勿直接执行）。默认按本文件位置推导仓库根；接入外部仓库时（scaffold）
# 先 export HARNESS_STACK_ROOT=<目标根> 覆盖。
#
#   函数：
#     stack_detect       → maven|gradle|go|rust|npm|python|shell|unknown（探测优先级单一来源）
#     stack_profile      → 单行 "k=v ..."（框架/ORM 架构画像；确定性事实、只当导航不当判断）
#     stack_manifests    → 每行一个 pom.xml / build.gradle(.kts)（供 gate 逐模块执行）
#     stack_packages     → 每行一个 package.json
#     stack_dep_files    → 每行一个依赖清单/锁文件（含 package-lock/yarn.lock/go.sum/Cargo.lock 等）
#     stack_compat_manifests → 每行一个承载「最低支持版本」声明的清单（不含锁文件；供 compat 门禁）
#     stack_java_runner  → 0 = 有可用 Java 构建 runner（模块 mvnw/gradlew 或全局 mvn/gradle）
#     stack_lint_script  → 0 = 有 package.json 声明了 "lint"

_have() { command -v "$1" >/dev/null 2>&1; }

# 路径给原生 python3 前归一化：MSYS2/Cygwin 下把 POSIX 路径转 Windows 形式（cygpath -w），
# 否则 $ROOT 作参数被 MSYS 自动转 Windows、stdin 的 specs 不转，两套路径盘符/挂载错位（Linux/macOS 透传）。
# scaffold 的 depgraph_run 与 harness-depgraph.sh 的多栈循环共用。
_winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

_stack_root() {
  printf '%s' "${HARNESS_STACK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
}
# _stack_find <maxdepth> <find 谓词...>：统一排除 node_modules/.git/target；恒返回 0（无匹配=空）。
_stack_find() {
  local depth="$1"; shift
  find "$(_stack_root)" -maxdepth "$depth" -type f "$@" \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/target/*' 2>/dev/null || true
}

stack_manifests() {
  _stack_find 5 \( -name pom.xml -o -name build.gradle -o -name build.gradle.kts \) | sort
}
stack_packages() {
  _stack_find 5 -name package.json | sort
}
# 依赖清单与锁文件（供 dep 门禁判定「本仓是否有依赖可查」）。刻意不设 maxdepth：
# 锁文件在 monorepo 里可能埋得很深（frontend/apps/x/pnpm-lock.yaml），漏一个 = 漏检该模块，
# 而漏检是危险失败模式。排除目录沿用 _stack_find 的 node_modules/.git/target。
# 依赖清单文件名 —— **单一真源**。`stack_dep_files`（find 表达式）与 `stack_is_dep_manifest`
# （谓词）都从它派生，调用方（如 `harness-tier.sh` 的风险嗅探）也不许再抄一份：
# 此前 tier 手抄了同一份 21 个名字（实测两份完全一致）—— 但那是**巧合维持的一致**。加一个生态
# （如 build.sbt）要改 2~3 处，漏一处的表现是「tier 判 light 而 dep 门禁判有依赖」两套事实不一致。
STACK_DEP_MANIFESTS="pom.xml build.gradle build.gradle.kts package.json package-lock.json \
yarn.lock pnpm-lock.yaml go.mod go.sum Cargo.toml Cargo.lock composer.json composer.lock \
requirements.txt pyproject.toml Pipfile Pipfile.lock Gemfile Gemfile.lock Podfile Podfile.lock"

stack_dep_files() {
  local expr=() n
  for n in $STACK_DEP_MANIFESTS; do
    [ "${#expr[@]}" -gt 0 ] && expr+=(-o)
    expr+=(-name "$n")
  done
  find "$(_stack_root)" -type f \( "${expr[@]}" \) \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/target/*' 2>/dev/null | sort
}

# 谓词：某个 basename 是不是依赖清单 —— 给「按文件名分类」的调用方用，免得它自己再抄一份清单。
stack_is_dep_manifest() {  # <basename> → 0=是
  local n
  for n in $STACK_DEP_MANIFESTS; do [ "$1" = "$n" ] && return 0; done
  return 1
}

# 兼容性声明清单（供 compat 门禁读「最低支持版本」声明）。与 stack_dep_files 同款排除，但
# **不含锁文件**——锁文件记录解析结果，不表达「本仓支持到哪一版」，放进判定集只会稀释信号。
# 不设 maxdepth：monorepo 里的 package.json / pom.xml 可能埋得很深，漏一个 = 漏检该模块。
stack_compat_manifests() {
  find "$(_stack_root)" -type f \
    \( -name package.json -o -name go.mod -o -name Cargo.toml \
       -o -name pom.xml -o -name build.gradle -o -name build.gradle.kts \
       -o -name pyproject.toml -o -name setup.py -o -name setup.cfg \) \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/target/*' 2>/dev/null | sort
}

stack_detect() {
  local f
  f="$(_stack_find 5 -name pom.xml | head -1)"; [ -n "$f" ] && { echo maven; return; }
  f="$(_stack_find 5 \( -name build.gradle -o -name build.gradle.kts \) | head -1)"; [ -n "$f" ] && { echo gradle; return; }
  [ -f "$(_stack_root)/go.mod" ] && { echo go; return; }
  [ -f "$(_stack_root)/Cargo.toml" ] && { echo rust; return; }
  f="$(_stack_find 5 -name package.json | head -1)"; [ -n "$f" ] && { echo npm; return; }
  f="$(_stack_find 4 \( -name pyproject.toml -o -name setup.py -o -name requirements.txt \) | head -1)"; [ -n "$f" ] && { echo python; return; }
  # 探测只做「标签」用 maxdepth 4；实际 shell lint 由 gate 穷尽扫描（不设 maxdepth），二者语义不同。
  f="$(_stack_find 4 -name '*.sh' | head -1)"; [ -n "$f" ] && { echo shell; return; }
  echo unknown
}

# 多栈自动推导：枚举仓库里所有「有源码的模块」，每行 "stack<TAB>module_root(绝对路径)"，供
# harness-depgraph.sh 无显式 --stack/--module-root 时逐栈抽图合并（ADR-0006 大仓导航）。
# 与 stack_detect（单标签探测）不同：这里按清单穷举，polyglot 仓库（如 Java 后端 + Vue 前端）能
# 一次出齐。规则：
#   - maven/gradle：每个 pom.xml / build.gradle(.kts) 一个模块，源码根 src/main/java（kotlin 则
#     src/main/kotlin）优先，否则回退清单目录。
#   - go / rust：单仓根（go.mod / Cargo.toml）。
#   - npm：每个 package.json 一个模块，源码根 src/ 优先。
#   - 聚合去重：某清单目录下还有更深层的同类型清单（monorepo 根/仓库根挂名标记，如根 package.json
#     下面还有 frontend/h5 各自的 package.json）时跳过该上层清单，只留真正的源码模块边界。
# 只读探测，不落盘；无匹配输出空（调用方据此兜底 unknown 目录树）。

# _has_nested <dir> <find 谓词...>：目录下（排除 node_modules/.git/target）是否还有更深层的同类型清单。
_has_nested() {
  local d="$1"; shift
  [ -n "$(find "$d" -mindepth 2 -maxdepth 6 "$@" \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/target/*' 2>/dev/null | head -1)" ]
}

stack_detect_all() {
  local root f d
  root="$(_stack_root)"

  while IFS= read -r f; do
    d="${f%/*}"
    _has_nested "$d" -name pom.xml && continue
    if [ -d "$d/src/main/java" ]; then printf 'maven\t%s\n' "$d/src/main/java"
    elif [ -d "$d/src/main/kotlin" ]; then printf 'maven\t%s\n' "$d/src/main/kotlin"
    else printf 'maven\t%s\n' "$d"; fi
  done < <(_stack_find 5 -name pom.xml)

  while IFS= read -r f; do
    d="${f%/*}"
    _has_nested "$d" \( -name build.gradle -o -name build.gradle.kts \) && continue
    if [ -d "$d/src/main/java" ]; then printf 'gradle\t%s\n' "$d/src/main/java"
    elif [ -d "$d/src/main/kotlin" ]; then printf 'gradle\t%s\n' "$d/src/main/kotlin"
    else printf 'gradle\t%s\n' "$d"; fi
  done < <(_stack_find 5 \( -name build.gradle -o -name build.gradle.kts \))

  [ -f "$root/go.mod" ] && printf 'go\t%s\n' "$root"
  [ -f "$root/Cargo.toml" ] && printf 'rust\t%s\n' "$root"

  while IFS= read -r f; do
    d="${f%/*}"
    _has_nested "$d" -name package.json && continue
    if [ -d "$d/src" ]; then printf 'npm\t%s\n' "$d/src"
    else printf 'npm\t%s\n' "$d"; fi
  done < <(_stack_find 5 -name package.json)

  [ -f "$root/pyproject.toml" ] && printf 'python\t%s\n' "$root"
  [ -f "$root/setup.py" ] && printf 'python\t%s\n' "$root"
}

stack_java_runner() {
  local m d
  while IFS= read -r m; do
    d="${m%/*}"
    [ -x "$d/mvnw" ] && return 0
    [ -x "$d/gradlew" ] && return 0
  done < <(stack_manifests)
  _have mvn || _have gradle
}

stack_lint_script() {
  local pkgs
  pkgs="$(stack_packages)"
  [ -n "$pkgs" ] || return 1
  printf '%s\n' "$pkgs" | xargs grep -ql '"lint"' 2>/dev/null
}

# 架构画像：从构建清单 grep 框架/ORM 信号，输出单行 "k=v ..."（空=未识别）。确定性事实、只当导航，
# 不判好坏（对齐 ADR-0006 判断/导航分离）。scaffold 的 arch.md facts 用它补「比单标签更细」的画像。
# 恒返回 0：无信号即空串，不让 set -e 在无匹配时中断调用方。
stack_profile() {
  local root f out=""
  root="$(_stack_root)"
  case "$(stack_detect)" in
    maven|gradle)
      f="$(_stack_find 5 -name pom.xml | head -1)"
      if [ -n "$f" ]; then
        grep -qE 'spring-boot' "$f" && out="$out framework=spring-boot"
        grep -qE 'mybatis' "$f" && out="$out orm=mybatis"
        grep -qE 'spring-boot-starter-data-jpa|artifactId>hibernate' "$f" && out="$out orm=jpa"
        grep -qE 'spring-boot-starter-data-mongodb' "$f" && out="$out orm=mongodb"
      fi
      ;;
    go)
      f="$root/go.mod"
      if [ -f "$f" ]; then
        grep -qE 'gin-gonic/gin' "$f" && out="$out framework=gin"
        grep -qE 'labstack/echo' "$f" && out="$out framework=echo"
        grep -qE 'go-chi/chi' "$f" && out="$out framework=chi"
      fi
      ;;
    npm)
      f="$(_stack_find 5 -name package.json | head -1)"
      if [ -n "$f" ]; then
        grep -qE '"vue"' "$f" && out="$out framework=vue"
        grep -qE '"react"' "$f" && out="$out framework=react"
        grep -qE '"next"' "$f" && out="$out framework=next"
      fi
      ;;
    rust)
      f="$root/Cargo.toml"
      if [ -f "$f" ]; then
        grep -qE 'axum' "$f" && out="$out framework=axum"
        grep -qE 'actix-web' "$f" && out="$out framework=actix-web"
      fi
      ;;
    python)
      f="$root/pyproject.toml"
      [ -f "$f" ] || f="$(_stack_find 4 -name requirements.txt | head -1)"
      if [ -n "$f" ] && [ -f "$f" ]; then
        grep -qiE 'django' "$f" && out="$out framework=django"
        grep -qiE 'fastapi' "$f" && out="$out framework=fastapi"
        grep -qiE 'flask' "$f" && out="$out framework=flask"
      fi
      ;;
  esac
  printf '%s\n' "${out# }"
}
