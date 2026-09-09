import torch
from torch import nn
from d2l import torch as d2l
from torch.utils.data import DataLoader
from torchvision import datasets, transforms
import copy
import json
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

#保存数据的函数
def export_for_soc(net, test_iter, out_dir="soc_export_int8"):
    out = Path(out_dir).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    scales = {}

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
        scales[f"{layer_name}_requant_multiplier"] = (
            bias_scale / output_scale
        )

    # 只保存第一张32x32测试图片，数据范围由[0, 1]量化到[0, 127]。
    save_int8("test_images", X[:1], scale=input_image_scale)

    # 标签是0～9的整数，直接保存
    y[:1].cpu().numpy().astype(np.int8).tofile(
        out / "test_labels.bin"
    )

    # 保存缩放比例，后续硬件计算时需要
    (out / "scales.json").write_text(
        json.dumps(scales, indent=2), encoding="utf-8"
    )

    print("保存位置：", out.resolve())

export_for_soc(net, test_iter)
