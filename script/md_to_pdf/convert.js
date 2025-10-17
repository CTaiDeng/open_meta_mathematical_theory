// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2025 GaoZheng

const {Notebook} = require('crossnote');
const path = require('path');
const fs = require('fs');

// 接收从 Python 传来的文件路径和输出目录
const mdFilePath = process.argv[2];
const outputDir = process.argv[3];

if (!mdFilePath || !outputDir) {
    console.error("错误：请提供 Markdown 文件路径和输出目录。");
    process.exit(1);
}

const absoluteMdPath = path.resolve(mdFilePath);
const workspaceDir = path.dirname(absoluteMdPath);

// 确保输出目录存在
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, {recursive: true});
}

// 主转换函数
async function convert() {
    try {
        // 初始化 Notebook 引擎
        const notebook = await Notebook.init({
            notebookPath: workspaceDir,
            config: {
                previewTheme: 'github-light.css',
                revealjsTheme: 'white.css',
                codeBlockTheme: 'default.css',
                printBackground: true,
                enableScriptExecution: true
            },
        });

        // 获取特定文件的 Markdown 引擎
        const engine = await notebook.getNoteMarkdownEngine(absoluteMdPath);

        // ======================= 修改部分开始 =======================

        // 1. 先让 crossnote 在默认位置生成 PDF 文件
        //    我们不再指定 destinationFilePath，让它返回实际生成的文件路径
        console.log("正在生成临时 PDF 文件...");
        const tempPdfPath = await engine.chromeExport({
            fileType: 'pdf',
            openFileAfterGeneration: false
        });
        console.log(`临时文件已生成于: ${tempPdfPath}`);

        // 2. 计算出我们期望的最终文件路径
        const finalPdfPath = path.join(outputDir, path.basename(tempPdfPath));

        // 3. 将生成的文件从临时位置移动到最终的目标位置
        //    fs.renameSync() 是移动文件的最快方式
        console.log(`正在移动文件至: ${finalPdfPath}`);
        fs.renameSync(tempPdfPath, finalPdfPath);

        // 4. 打印最终的成功信息
        console.log(`✅ 成功转换并移动至: ${finalPdfPath}`);

        // ======================= 修改部分结束 =======================

    } catch (error) {
        console.error(`转换失败: ${error}`);
        process.exit(1);
    }
}

convert();
