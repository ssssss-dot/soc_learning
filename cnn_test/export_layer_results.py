"""从acc_demo导出的bin生成逐层整数参考结果，不需要重新训练。

运行：python export_layer_results.py --data-dir soc_export_int8
输出顺序与硬件一致：图像按[通道][行][列]，FC按输出神经元编号。
"""

import argparse
import csv
import json
import struct
from pathlib import Path


def read_int8(path, size):
    data = path.read_bytes()
    if len(data) != size:
        raise ValueError(f"{path.name}应有{size}字节，实际为{len(data)}字节")
    return list(struct.unpack(f"{size}b", data))


def read_bias(path, count):
    data = path.read_bytes()
    if len(data) != count * 4:
        raise ValueError(f"{path.name}应有{count}个INT32偏置")
    return list(struct.unpack(f"<{count}i", data))


def signed_int32(value):
    # 与硬件32位累加器的补码截断一致。
    return ((value + (1 << 31)) % (1 << 32)) - (1 << 31)


def requantize(values, mult, shift, relu, conv=False):
    """模拟现有Conv/FC的整数乘法、舍入、算术右移和INT8限幅。"""
    if not isinstance(mult, int) or not 1 <= mult <= 0xFFFFFFFF:
        raise ValueError("quant_mult必须是非零32位无符号整数")
    if not isinstance(shift, int) or not 0 <= shift <= 63:
        raise ValueError("quant_shift必须在0～63之间")

    output = []
    for value in values:
        product = signed_int32(value) * mult
        bias = 0
        if shift != 0:
            if conv:
                # Conv负数随后被ReLU归零，现有RTL不对负数加舍入偏移。
                if product >= 0:
                    bias = 1 << (shift - 1)
            else:
                # FC支持负数：半值远离0，与fc_int32_int8一致。
                bias = (1 << (shift - 1)) - int(product < 0)
        scaled = (product + bias) >> shift
        if relu:
            scaled = max(0, scaled)
        output.append(max(-128, min(127, scaled)))
    return output


def conv5x5(inputs, shape, weights, biases):
    """输入[通道][行][列]；文件权重[输入通道][核位置][16个PE行]。"""
    in_channels, height, width = shape
    if len(inputs) != in_channels * height * width:
        raise ValueError("卷积输入长度与形状不一致")
    if height < 5 or width < 5 or len(weights) != in_channels * 25 * 16:
        raise ValueError("当前参考卷积只支持5×5、stride=1、无padding")
    if not 1 <= len(biases) <= 16:
        raise ValueError("卷积输出通道数必须为1～16")

    out_height, out_width = height - 4, width - 4
    sums = []
    for oc, bias in enumerate(biases):
        for y in range(out_height):
            for x in range(out_width):
                total = bias
                for ic in range(in_channels):
                    for ky in range(5):
                        for kx in range(5):
                            pixel_index = (ic * height + y + ky) * width + x + kx
                            weight_index = (ic * 25 + ky * 5 + kx) * 16 + oc
                            total += inputs[pixel_index] * weights[weight_index]
                sums.append(signed_int32(total))
    return sums, (len(biases), out_height, out_width)


def max_pool2x2(inputs, shape):
    """每通道独立做2×2最大池化，stride=2；输出不重新量化。"""
    channels, height, width = shape
    if height % 2 or width % 2 or len(inputs) != channels * height * width:
        raise ValueError("当前池化要求宽高为偶数，且输入长度正确")
    output = []
    for channel in range(channels):
        for y in range(0, height, 2):
            for x in range(0, width, 2):
                top = (channel * height + y) * width + x
                output.append(max(inputs[top], inputs[top + 1],
                                  inputs[top + width], inputs[top + width + 1]))
    return output, (channels, height // 2, width // 2)


def fully_connected(inputs, weights, biases):
    """文件权重[输出组][输入特征][16个PE列]，尾组补零。"""
    in_features = len(inputs)
    groups = (len(biases) + 15) // 16
    if len(weights) != groups * in_features * 16:
        raise ValueError("FC权重长度不符合16列分组补齐格式")
    sums = []
    for oc, bias in enumerate(biases):
        group, lane = divmod(oc, 16)
        total = bias
        for k, value in enumerate(inputs):
            weight_index = (group * in_features + k) * 16 + lane
            total += value * weights[weight_index]
        sums.append(signed_int32(total))
    return sums


def export_layer_results(data_dir="soc_export_int8"):
    """只读取已导出的模型文件，写出layer_results.csv，返回路径和分类结果。"""
    folder = Path(data_dir).expanduser()
    scales = json.loads((folder / "scales.json").read_text(encoding="utf-8"))
    if scales.get("_conv_weight_layout", {}).get("layout") != \
            "[input_channel][kernel_index][pe_row]":
        raise ValueError("scales.json中的Conv权重排列不符合当前硬件")
    fc_layout = scales.get("_fc_weight_layout", {})
    if fc_layout.get("layout") != "[output_group][input_index][pe_col]":
        raise ValueError("请使用新版FC分组导出文件，不能使用旧的[输出][输入]排列")

    # stage保存每一层的形状、最终INT8输出和可选的加bias后INT32结果。
    stages = []
    data = read_int8(folder / "test_images.bin", 1024)
    if any(value < 0 for value in data):
        raise ValueError("当前MNIST输入图片应为0～127")
    shape = (1, 32, 32)
    stages.append(("input", shape, data, None))

    for name, out_channels in (("conv1", 6), ("conv2", 16)):
        weights = read_int8(folder / f"{name}_weight.bin", shape[0] * 25 * 16)
        biases = read_bias(folder / f"{name}_bias.bin", out_channels)
        sums, shape = conv5x5(data, shape, weights, biases)
        data = requantize(sums, scales[f"{name}_quant_mult"],
                          scales[f"{name}_quant_shift"], relu=True, conv=True)
        # Conv的CSV输出已包含ReLU和量化，正是共享BRAM中的INT8结果。
        stages.append((name, shape, data, sums))
        data, shape = max_pool2x2(data, shape)
        stages.append((name.replace("conv", "pool"), shape, data, None))

    # Flatten不改变数据顺序：16×5×5连续展平为400个特征。
    stages.append(("flatten", (len(data),), data, None))
    for name, out_features in (("fc1", 96), ("fc2", 64), ("fc3", 10)):
        in_features = len(data)
        groups = (out_features + 15) // 16
        expected_shape = [groups, in_features, 16]
        info = fc_layout.get("layers", {}).get(f"{name}_weight", {})
        if info.get("shape") != expected_shape:
            raise ValueError(f"{name}的权重形状应为{expected_shape}")
        weights = read_int8(folder / f"{name}_weight.bin", groups * in_features * 16)
        biases = read_bias(folder / f"{name}_bias.bin", out_features)
        sums = fully_connected(data, weights, biases)
        data = requantize(sums, scales[f"{name}_quant_mult"],
                          scales[f"{name}_quant_shift"], relu=(name != "fc3"))
        stages.append((name, (out_features,), data, sums))

    csv_path = folder / "layer_results.csv"
    with csv_path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle)
        writer.writerow(["layer", "index", "channel", "row", "col",
                         "word_offset", "byte_lane", "accum_int32",
                         "value_int8", "byte_hex"])
        for name, stage_shape, values, sums in stages:
            for index, value in enumerate(values):
                if len(stage_shape) == 3:
                    _, height, width = stage_shape
                    channel, within_channel = divmod(index, height * width)
                    y, x = divmod(within_channel, width)
                else:
                    # FC/Flatten只按index编号，不伪造图像坐标。
                    channel, y, x = "", "", ""
                writer.writerow([name, index, channel, y, x,
                                 index // 4, index % 4,
                                 "" if sums is None else sums[index],
                                 value, f"{value & 0xFF:02X}"])

    labels = (folder / "test_labels.bin").read_bytes()
    if len(labels) != 1 or labels[0] > 9:
        raise ValueError("test_labels.bin必须保存一个0～9的标签")
    prediction = max(range(len(data)), key=lambda index: data[index])
    return csv_path, prediction, labels[0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="从模型bin生成上板逐层对照CSV")
    parser.add_argument("--data-dir", default="soc_export_int8", help="模型bin和scales.json所在目录")
    args = parser.parse_args()
    path, prediction, label = export_layer_results(args.data_dir)
    print(f"CSV：{path.resolve()}")
    print(f"整数模型预测：{prediction}，图片标签：{label}")
