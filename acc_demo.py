import torch
from torch import nn
from d2l import torch as d2l
from torch.utils.data import DataLoader
from torchvision import datasets, transforms
import copy
import json
import math
from collections import OrderedDict
from pathlib import Path
import numpy as np

def load_data_mnist(batch_size, resize=None):
    trans = []

    if resize is not None:
        trans.append(transforms.Resize(resize))

    trans.append(transforms.ToTensor())
    trans = transforms.Compose(trans)

    train_dataset = datasets.MNIST(
        root="./data",
        train=True,
        transform=trans,
        download=True
    )

    test_dataset = datasets.MNIST(
        root="./data",
        train=False,
        transform=trans,
        download=True
    )

    train_iter = DataLoader(
        train_dataset,
        batch_size=batch_size,
        shuffle=True,
        num_workers=0
    )

    test_iter = DataLoader(
        test_dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=0
    )

    return train_iter, test_iter

train_iter, test_iter = load_data_mnist(batch_size=256 ,  resize = 32)#不用padding，所以resize为32*32

# 给层命名，导出文件时能直接识别conv1、fc1等
#OrderedDict 是 Python 的“有序字典”。在这里用来给网络每一层命名，并保持排列顺序
net = nn.Sequential(OrderedDict([
    ("conv1", nn.Conv2d(
        1, 6, kernel_size=5, stride=1, padding=0, bias=True
    )),
    ("relu1", nn.ReLU()),
    ("pool1", nn.MaxPool2d(kernel_size=2, stride=2)),

    ("conv2", nn.Conv2d(
        6, 16, kernel_size=5, stride=1, padding=0, bias=True
    )),
    ("relu2", nn.ReLU()),
    ("pool2", nn.MaxPool2d(kernel_size=2, stride=2)),

    ("flatten", nn.Flatten()),

    ("fc1", nn.Linear(400, 96)),
    ("relu3", nn.ReLU()),

    ("fc2", nn.Linear(96, 64)),
    ("relu4", nn.ReLU()),

    ("fc3", nn.Linear(64, 10))
]))

if torch.cuda.is_available():
    device = torch.device("cuda")
elif torch.backends.mps.is_available():
    device = torch.device("mps")
else:
    device = torch.device("cpu")

print("训练设备：", device)
net = net.to(device)

#训练
num_epochs = 10
lr = 0.05  # 起始学习率，可根据训练表现调整

d2l.train_ch6(
    net=net,
    train_iter=train_iter,
    test_iter=test_iter,
    num_epochs=num_epochs,
    lr=lr,
    device=device
)

def get_requant_params(ratio):
    """把正的缩放比例转换为32位无符号MULT和6位SHIFT。"""
    if not math.isfinite(ratio) or ratio <= 0:
        raise ValueError(f"量化缩放比例必须是有限正数：{ratio}")

    # 优先使用较大的SHIFT保留精度，MULT必须能装入32位寄存器。
    for shift in range(63, -1, -1):
        scaled = ratio * (1 << shift)
        if not math.isfinite(scaled):
            continue
        mult = round(scaled)
        if 1 <= mult <= 0xFFFFFFFF:
            # 约去公共的2因子，例如把1/16直接表示为MULT=1、SHIFT=4。
            while shift > 0 and mult % 2 == 0:
                mult //= 2
                shift -= 1
            return mult, shift

    raise ValueError(f"量化缩放比例超出MULT/SHIFT可表示范围：{ratio}")


#保存数据的函数
def export_for_soc(net, test_iter, out_dir="soc_export_int8"):
    out = Path(out_dir).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    scales = {
        "_quantization": {
            "description": "每层的quant_mult、quant_shift是可写入硬件寄存器的整数值；同层所有输出通道共用。",
            "quant_mult_bits": 32,
            "quant_mult_signed": False,
            "quant_shift_bits": 6,
            "quant_shift_range": [0, 63],
            "quant_shift_note": "32位寄存器仅低6位有效，其余位写0。",
            "target_formula": "input_scale * weight_scale / output_scale",
            "hardware_scale_formula": "quant_mult / (2 ** quant_shift)",
            "product_note": "int32累加结果乘无符号quant_mult，乘积使用64位有符号数保存。"
        },
        "_conv_weight_layout": {
            "layout": "[input_channel][kernel_index][pe_row]",
            "pe_rows": 16,
            "kernel_index": "kernel_y * kernel_width + kernel_x",
            "padding": "输出通道不足16时，高编号PE行的权重补0。",
            "address_formula": "((input_channel * kernel_elements + kernel_index) * 16 + pe_row) bytes"
        }
    }

    def get_int8_scale(tensor):
        max_value = float(tensor.detach().abs().max().item())
        return max_value / 127.0 if max_value > 0 else 1.0

    # 浮点数先缩放、取整，再保存成INT8
    def save_int8(name, tensor, scale=None):
        data = tensor.detach().cpu().float().numpy()

        if scale is None:
            scale = get_int8_scale(tensor)

        data_int8 = np.clip(
            np.rint(data / scale), -127, 127
        ).astype(np.int8)

        data_int8.tofile(out / f"{name}.bin")
        scales[name] = float(scale)
        return float(scale)

    # 把PyTorch卷积权重[Cout][Cin][Kh][Kw]重排成硬件PE阵列需要的
    # [Cin][Kh*Kw][16]。固定输入通道和卷积核位置时，16个PE行的
    # 权重连续存放，BRAM连续读取4个32位字即可组成完整权重向量。
    def save_conv_weight_int8(name, tensor, pe_rows=16, scale=None):
        data = tensor.detach().cpu().float().numpy()

        if data.ndim != 4:
            raise ValueError(
                f"{name}必须是[Cout][Cin][Kh][Kw]四维卷积权重，"
                f"实际形状为{data.shape}"
            )

        if scale is None:
            scale = get_int8_scale(tensor)

        data_int8 = np.clip(
            np.rint(data / scale), -127, 127
        ).astype(np.int8)

        out_channels, in_channels, kernel_height, kernel_width = (
            data_int8.shape
        )
        if out_channels > pe_rows:
            raise ValueError(
                f"{name}有{out_channels}个输出通道，"
                f"超过当前PE阵列的{pe_rows}行"
            )

        kernel_elements = kernel_height * kernel_width
        weight_pe = np.zeros(
            (in_channels, kernel_elements, pe_rows),
            dtype=np.int8
        )
        weight_pe[:, :, :out_channels] = data_int8.transpose(
            1, 2, 3, 0
        ).reshape(in_channels, kernel_elements, out_channels)

        weight_pe.tofile(out / f"{name}.bin")
        scales[name] = float(scale)
        return float(scale)

    # 偏置必须与PE的INT32累加结果使用相同尺度：
    # bias_scale = input_scale * weight_scale。
    def save_bias_int32(name, tensor, input_scale, weight_scale):
        data = tensor.detach().cpu().double().numpy()
        acc_scale = float(input_scale) * float(weight_scale)

        int32_info = np.iinfo(np.int32)
        data_int32 = np.clip(
            np.rint(data / acc_scale),
            int32_info.min,
            int32_info.max
        ).astype("<i4")

        data_int32.tofile(out / f"{name}.bin")
        scales[name] = acc_scale
        return acc_scale

    # 用一个测试批次估计各层激活范围。conv/relu/pool视为一个输出阶段，
    # 全连接层与紧随其后的ReLU视为一个输出阶段。
    X, y = next(iter(test_iter))

    input_image_scale = 1.0 / 127.0
    layer_scales = {}

    was_training = net.training
    net.eval()
    with torch.no_grad():
        value = X.to(device)

        value = net.pool1(net.relu1(net.conv1(value)))
        layer_scales["conv1"] = {
            "input_scale": input_image_scale,
            "output_scale": get_int8_scale(value)
        }

        conv2_input_scale = layer_scales["conv1"]["output_scale"]
        value = net.pool2(net.relu2(net.conv2(value)))
        layer_scales["conv2"] = {
            "input_scale": conv2_input_scale,
            "output_scale": get_int8_scale(value)
        }

        fc1_input_scale = layer_scales["conv2"]["output_scale"]
        value = net.flatten(value)
        value = net.relu3(net.fc1(value))
        layer_scales["fc1"] = {
            "input_scale": fc1_input_scale,
            "output_scale": get_int8_scale(value)
        }

        fc2_input_scale = layer_scales["fc1"]["output_scale"]
        value = net.relu4(net.fc2(value))
        layer_scales["fc2"] = {
            "input_scale": fc2_input_scale,
            "output_scale": get_int8_scale(value)
        }

        fc3_input_scale = layer_scales["fc2"]["output_scale"]
        value = net.fc3(value)
        layer_scales["fc3"] = {
            "input_scale": fc3_input_scale,
            "output_scale": get_int8_scale(value)
        }

    if was_training:
        net.train()

    # 权重保存为INT8；偏置保存为与对应INT32累加器同尺度的INT32。
    for layer_name in ("conv1", "conv2", "fc1", "fc2", "fc3"):
        layer = net.get_submodule(layer_name)
        input_scale = layer_scales[layer_name]["input_scale"]
        output_scale = layer_scales[layer_name]["output_scale"]

        if isinstance(layer, nn.Conv2d):
            weight_scale = save_conv_weight_int8(
                f"{layer_name}_weight", layer.weight
            )
        else:
            weight_scale = save_int8(
                f"{layer_name}_weight", layer.weight
            )
        bias_scale = save_bias_int32(
            f"{layer_name}_bias",
            layer.bias,
            input_scale,
            weight_scale
        )

        # PE的INT32结果重新量化成下一层INT8输入时使用该乘数。
        scales[f"{layer_name}_input_scale"] = input_scale
        scales[f"{layer_name}_output_scale"] = output_scale
        scales[f"{layer_name}_acc_scale"] = bias_scale
        ratio = bias_scale / output_scale
        mult, shift = get_requant_params(ratio)
        scales[f"{layer_name}_requant_multiplier"] = ratio
        scales[f"{layer_name}_quant_mult"] = mult
        scales[f"{layer_name}_quant_shift"] = shift
        scales[f"{layer_name}_requant_multiplier_approx"] = mult / (1 << shift)

    # 只保存第一张32x32测试图片，数据范围由[0, 1]量化到[0, 127]。
    save_int8("test_images", X[:1], scale=input_image_scale)

    # 标签是0～9的整数，直接保存
    y[:1].cpu().numpy().astype(np.int8).tofile(
        out / "test_labels.bin"
    )

    # 保存缩放比例，后续硬件计算时需要
    (out / "scales.json").write_text(
        json.dumps(scales, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    print("保存位置：", out.resolve())

export_for_soc(net, test_iter)
