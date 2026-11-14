#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "1/3 运行本地临床与声学 DSP 单元测试..."
/usr/bin/swiftc -parse-as-library \
  HearGuard/Models/AudiometryModels.swift \
  HearGuard/DSP/AcousticMath.swift \
  HearGuard/DSP/HughsonWestlakeEngine.swift \
  HearGuard/DSP/ClinicalAnalyzer.swift \
  Tests/verify_audiometry.swift \
  -o /tmp/verify_audiometry && /tmp/verify_audiometry

echo "2/3 推送至私有构建仓库并触发 macOS-15 ARM64 iOS IPA 编译..."
git add -A
git diff --cached --quiet || git commit -m "Update HearGuard iOS app"
git push origin main

sleep 3
RUN_ID=$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')
echo "等待云端 Xcode 编译完成 (Run ID: ${RUN_ID})..."
gh run watch "${RUN_ID}" --exit-status

echo "3/3 下载 HearGuard.ipa 到当前目录与桌面..."
rm -rf build/artifact_dl
gh run download "${RUN_ID}" -n HearGuard-iOS-IPA -D build/artifact_dl
cp build/artifact_dl/HearGuard.ipa ./HearGuard.ipa
echo "✅ 编译完成！IPA 文件位于: $(pwd)/HearGuard.ipa"
