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

    ("fc1", nn.Linear(400, 120)),
    ("relu3", nn.ReLU()),

    ("fc2", nn.Linear(120, 84)),
    ("relu4", nn.ReLU()),

    ("fc3", nn.Linear(84, 10))
]))

device = torch.device("cuda")
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

    # 浮点数先缩放、取整，再保存成INT8
    def save_int8(name, tensor, scale=None):
        data = tensor.detach().cpu().float().numpy()

        if scale is None:
            max_value = float(np.abs(data).max())
            scale = max_value / 127 if max_value > 0 else 1.0

        data_int8 = np.clip(
            np.rint(data / scale), -127, 127
        ).astype(np.int8)

        data_int8.tofile(out / f"{name}.bin")
        scales[name] = scale

    # 保存全部权重和bias
    for name, parameter in net.named_parameters():
        save_int8(name.replace(".", "_"), parameter)

    # 保存第一批中的前10张图片，要求是ToTensor后的[0,1]数据
    X, y = next(iter(test_iter))
    save_int8("test_images", X[:10], scale=1.0 / 127)

    # 标签是0～9的整数，直接保存
    y[:10].cpu().numpy().astype(np.int8).tofile(
        out / "test_labels.bin"
    )

    # 保存缩放比例，后续硬件计算时需要
    (out / "scales.json").write_text(
        json.dumps(scales, indent=2), encoding="utf-8"
    )

    print("保存位置：", out.resolve())

