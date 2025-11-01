# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

import os
from pathlib import Path

from batch_convert import batch_convert_md_to_pdf


ROOT_DIRECTORY = str(Path(__file__).resolve().parents[2])
INPUT_DIRECTORY = os.path.join(ROOT_DIRECTORY, 'src', 'kernel_plus')
OUTPUT_DIRECTORY = os.path.join(ROOT_DIRECTORY, 'src', 'kernel_plus_pdf')


if __name__ == '__main__':
    batch_convert_md_to_pdf(INPUT_DIRECTORY, OUTPUT_DIRECTORY)

