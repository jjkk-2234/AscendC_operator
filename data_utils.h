/**
 * Copyright (c) 2026 Huawei Technologies Co., Ltd.
 * This program is free software, you can redistribute it and/or modify it under the terms and conditions of
 * CANN Open Software License Agreement Version 2.0 (the "License").
 * Please refer to the License for details. You may not use this file except in compliance with the License.
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR A PARTICULAR PURPOSE.
 * See LICENSE in the root of the software repository for the full text of the License.
 */

/* !
 * \file data_utils.h
 * \brief 数据读入写出函数（host 侧用）
 *
 * 用法约定（本目录内所有 .asc 统一遵守）：
 *   ReadFile ("./input/input_x.bin",     fileSize, xHost,     xBytes);
 *   ReadFile ("./input/input_scale.bin", fileSize, scaleHost, scaleBytes);
 *   WriteFile("./output/output.bin",     zHost,    zBytes);
 *
 * 注意：
 *   1) 路径里的 './' 是**进程的当前工作目录**，不是可执行文件所在目录。
 *      所以必须在源码根目录（dequant_asc/）下运行，或在 build/ 下同时生成 input/。
 *   2) ReadFile 的第二个参数是**出参**（实际读到的字节数），
 *      调用方应当校验它是否等于期望值，否则可能读到短文件。
 */

#ifndef DATA_UTILS_H
#define DATA_UTILS_H
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
#include <fstream>
#include <string>

#define ERROR_LOG(fmt, args...) fprintf(stdout, "[ERROR]  " fmt "\n", ##args)

inline bool ReadFile(const std::string& filePath, size_t& fileSize, void* buffer, size_t bufferSize)
{
    struct stat sBuf;
    int fileStatus = stat(filePath.data(), &sBuf);
    if (fileStatus == -1) {
        ERROR_LOG("failed to get file: %s", filePath.c_str());
        return false;
    }
    if (S_ISREG(sBuf.st_mode) == 0) {
        ERROR_LOG("%s is not a file, please enter a file", filePath.c_str());
        return false;
    }

    std::ifstream file;
    file.open(filePath, std::ios::binary);
    if (!file.is_open()) {
        ERROR_LOG("Open file failed. path = %s", filePath.c_str());
        return false;
    }

    std::filebuf* buf = file.rdbuf();
    size_t size = buf->pubseekoff(0, std::ios::end, std::ios::in);
    if (size == 0) {
        ERROR_LOG("file size is 0: %s", filePath.c_str());
        file.close();
        return false;
    }
    if (size > bufferSize) {
        ERROR_LOG("file size(%zu) is larger than buffer size(%zu): %s", size, bufferSize, filePath.c_str());
        file.close();
        return false;
    }
    buf->pubseekpos(0, std::ios::in);
    buf->sgetn(static_cast<char*>(buffer), size);
    fileSize = size;
    file.close();
    return true;
}

inline bool WriteFile(const std::string& filePath, const void* buffer, size_t size)
{
    if (buffer == nullptr) {
        ERROR_LOG("Write file failed. buffer is nullptr");
        return false;
    }

    int fd = open(filePath.c_str(), O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR);
    if (fd < 0) {
        ERROR_LOG("Open file failed. path = %s", filePath.c_str());
        return false;
    }

    ssize_t writeSize = write(fd, buffer, size);
    close(fd);
    if (writeSize < 0 || static_cast<size_t>(writeSize) != size) {
        ERROR_LOG("Write file Failed. path = %s", filePath.c_str());
        return false;
    }

    return true;
}

/**
 * \brief 从文件读入并校验字节数（推荐直接用这个，避免漏掉 fileSize 校验）
 * \return 实际读到字节数是否等于 expectBytes
 */
inline bool ReadFileChecked(const std::string& filePath, void* buffer, size_t expectBytes)
{
    size_t got = 0;
    if (!ReadFile(filePath, got, buffer, expectBytes)) {
        return false;
    }
    if (got != expectBytes) {
        ERROR_LOG("file '%s' size mismatch: expect %zu bytes, got %zu bytes "
                  "(元素个数不一致？检查 gen_data.py --m/--n 与命令行参数)",
                  filePath.c_str(), expectBytes, got);
        return false;
    }
    return true;
}

#endif // DATA_UTILS_H
