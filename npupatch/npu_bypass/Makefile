obj-m += npu_bypass.o
KDIR := /lib/modules/$(shell uname -r)/build
all:
	make -C $(KDIR) M=$(PWD) modules
clean:
	make -C $(KDIR) M=$(PWD) clean
install:
	cp npu_bypass.ko /lib/modules/$(shell uname -r)/updates/
	depmod -a
