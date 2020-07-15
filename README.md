# mylib

**mylib** is a helper library with algorithms and data structures that I reuse
in personal scripts and program.

It is made for my personal needs so if you use it be aware that it may change
at any time. But well, the API will be pretty stable because changes to it
leads to a multitude of my personal scripts and programs breaking.

# Getting Started

mylib depends on the following software packages:

 * [D compiler](https://dlang.org/download.html) (dmd 2.079+, ldc 1.11.0+)

It is recommended to install the D compiler by downloading it from the official distribution page.
```sh
# link https://dlang.org/download.html
curl -fsS https://dlang.org/install.sh | bash -s dmd
```

For users running Ubuntu one of the dependencies can be installed with apt.
```sh
sudo apt install x
```

Download the D compiler of your choice, extract it and add to your PATH shell
variable.
```sh
# example with an extracted DMD
export PATH=/path/to/dmd/linux/bin64/:$PATH
```

Once the dependencies are installed it is time to download the source code to install mylib.
```sh
git clone https://github.com/joakim-brannstrom/mylib.git
cd mylib
dub build -b release
```

Done! Have fun.
Don't be shy to report any issue that you find.

# Credit
TODO
