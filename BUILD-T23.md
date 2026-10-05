# Build T23 NOR 8 MB

Preset: `t23_lite`. Firmware nền cho Lumi, đã tắt Majestic/webui/fonts;
streamer Lumi chưa được tích hợp nên bản này chưa phát video.
Các package mạng và driver còn lại theo preset OpenIPC.

Từ thư mục `lumi-ipc-firmware`:

```sh
docker build -t lumi-ipc-builder:openipc-t23 ../lumi-ipc-builder
docker run --rm --user "$(id -u):$(id -g)" --cpuset-cpus 0-7 \
  --env PWD=/work \
  --mount "type=bind,source=$(pwd),target=/work" --workdir /work \
  lumi-ipc-builder:openipc-t23 \
  make BOARD=t23_lite TARGET=/work/output/t23-nor8 \
    BR2_DL_DIR=/work/output/t23-nor8/dl \
    BR2_CCACHE_DIR=/work/output/t23-nor8/ccache
```

Lệnh trên dùng 8 CPU; điều chỉnh `--cpuset-cpus` theo máy build.
`PWD=/work` cần thiết vì Makefile OpenIPC dùng biến này để tìm external tree.
Buildroot và package sources được Makefile tải; không có lớp build riêng.

Output: `output/t23-nor8/images/openipc.t23-nor-lite.tgz`, chứa kernel và rootfs.
Giới hạn layout OpenIPC NOR 8 MB: kernel 2 MiB, rootfs 5 MiB. Đây không phải
full dump 8 MB và không kèm bootloader/environment/calibration của board.
Boot, sensor, Wi-Fi và partition thực tế cần kiểm tra trên đúng board trước flash.

## Kết quả build ban đầu 2026-09-15 (trước fixed login)

Build native hoàn tất trong 08:49, nền commit
`06b68e7bd4cfa68e36964ba75c8d56d1df6755ae` cùng thay đổi tắt Majestic trong preset T23.

| Artifact | Bytes | Giới hạn |
| --- | ---: | ---: |
| `uImage.t23` | 1,536,520 | 2,097,152 |
| `rootfs.squashfs.t23` | 3,641,344 | 5,242,880 |
| `openipc.t23-nor-lite.tgz` | 5,176,149 | Gói nén chứa hai partition |

Đã kiểm tra kích thước chính xác, checksum trong archive, nội dung archive khớp
file ngoài, header kernel MIPS/Linux 3.10.14 và BusyBox MIPS little-endian/musl.
Squashfs không có Majestic binary/service/EULA. CI matrix self-test qua 56 cases.
Chưa flash hoặc thử trên board.

SHA256 của `openipc.t23-nor-lite.tgz`:
`98f6b1dbbb864e35c7f8651843690569b2d6c49d199b2ebb6211dbb8d27f2bf7`.

## Full image T23N NOR 8 MiB — NeoProgrammer

File: `output/t23-nor8/images/lumi-t23n-nor8-full.bin`, **8,388,608 bytes**.
Gồm SPL + U-Boot T23N, kernel và rootfs ở trên. U-Boot dùng preset
`isvp_t23_sfcnor`, DDR2 64 MiB; chưa xác nhận DDR/boot trên board thực tế.

| Vùng | Offset | Dung lượng |
| --- | --- | ---: |
| SPL + U-Boot | `0x000000` | 256 KiB |
| Environment | `0x040000` | 64 KiB |
| Kernel | `0x050000` | 2048 KiB |
| Rootfs | `0x250000` | 5120 KiB |
| Rootfs data | `0x750000` | 704 KiB |

Layout theo `include/configs/isvp_common.h` trong fork U-Boot.
Mọi khoảng trống, environment và rootfs data đều là `0xFF`. Environment trống
khiến U-Boot dùng defaults đã compile rồi saveenv; `/init` chuẩn bị JFFS2 overlay
khi khởi động. Đây là image mới, **không giữ dữ liệu nhà máy, MAC/config hoặc
calibration từ firmware gốc**. Không chứa streamer Lumi/Majestic nên chưa có video.

Ghép lại từ các artifact local (không tải binary bên ngoài), chạy tại repo firmware:

```sh
python3 contrib/pack-t23n-nor8.py \
  --uboot ../lumi-u-boot-ingenic/output/u-boot-t23n-nor.bin \
  --kernel output/t23-nor8/images/uImage.t23 \
  --rootfs output/t23-nor8/images/rootfs.squashfs.t23 \
  --output output/t23-nor8/images/lumi-t23n-nor8-full.bin
python3 contrib/test-pack-t23n-nor8.py
```

Script từ chối ghi đè file đã tồn tại; dùng tên output mới cho bản build tiếp theo.
Kiểm tra giới hạn partition, CRC header/payload U-Boot LZO và kernel, superblock
SquashFS và đọc lại output. Những kiểm tra này không thay thế thử boot phần cứng.

SHA256 full image:
`44543bc5e675e6c35bdc1fd5714b9dbe60fd6a7c4ee58805c0670577b08fbbec`.

Trước khi nạp:

1. Đọc và lưu full dump firmware gốc; đọc lần hai, so sánh hai file để kiểm tra
   kết nối programmer ổn định. Giữ backup ngoài thư mục output.
2. Xác định đúng mã IC NOR và điện áp theo datasheet của IC; dung lượng phải là
   64 Mbit (8 MiB). Không cấp nguồn đồng thời từ camera và programmer.
3. Có UART để theo dõi/recovery; bản này chưa được thử boot trên camera.
4. Trong NeoProgrammer, chọn đúng chip, mở **full `.bin`**, ghi từ địa chỉ `0x000000`
   trên toàn bộ chip: erase, blank check, program rồi verify. Không dùng `.tgz`.
5. Đọc lại đủ 8 MiB và so sánh với full image **trước lần boot đầu tiên**;
   sau boot environment/overlay sẽ thay đổi. Nếu verify sai, không cấp nguồn boot.

Bản `lumi-t23n-nor8-full.bin` ban đầu yêu cầu tự đặt mật khẩu root lần đầu.
Sensor, Wi-Fi và khả năng boot vẫn cần kiểm tra trên board T23N thực tế.

## Bản fixed login cho bring-up

Overlay chung Lumi đặt tài khoản **root / LumiVn@2026** cho mọi dòng chip,
áp dụng cả console và SSH.
Không tự động đăng nhập, không bắt đổi mật khẩu lần đầu; vẫn có thể dùng `passwd`
để đổi về sau. Đây là mật khẩu dùng chung theo yêu cầu, **không phải cải thiện
bảo mật**; chỉ nên dùng trong mạng lab tin cậy, không triển khai nguyên trạng.

Sửa trực tiếp `general/overlay/etc/passwd` và `general/overlay/etc/shadow`:
SHA-512-crypt có salt, không lưu mật khẩu plaintext trong image, root dùng `/bin/sh`.
`general/scripts/rootfs_script.sh` đặt mode 0600 cho shadow và từ chối build nếu
còn Majestic/EULA để không bỏ qua chấp thuận license. Các preset upstream còn
bật Majestic phải tắt package này trước khi build firmware Lumi.
Đã bỏ hook T23 và test riêng của hook; không ghi đè mật khẩu ở mỗi lần boot.

Build bằng lệnh đầu tài liệu rồi ghép lại bằng lệnh ở trên, đổi tên output thành
`output/t23-nor8/images/lumi-t23n-nor8-full-shared-login.bin`.
Bản full image cũ được giữ nguyên; kernel/rootfs và `.tgz` trong images được
native build tạo lại nên các checksum lịch sử ở trên không áp dụng cho chúng nữa.

Nếu nâng cấp giữ overlay cũ, mật khẩu/shell đã lưu trong overlay có thể vẫn được
giữ lại. Full image mới có overlay trống nên dùng đúng tài khoản mặc định này.

Bản fixed-login trước khi chuyển sang overlay chung đã build trong 01:23;
kiểm tra trực tiếp SquashFS đã đóng gói:
hash khớp mật khẩu yêu cầu, root dùng `/bin/sh`, không ép đổi mật khẩu, shadow
thuộc root:root với mode 0600, không có Majestic/EULA. Hai test hook, ba test
packer và CI matrix 56 cases đều đạt. Chưa thử đăng nhập trên phần cứng.

Full fixed-login image: **8,388,608 bytes**, SHA256:
`b25ca2cf849543a6ac40a2b146641fd9a7da90f9682a9c2899c9af399b6b8aa0`.

Bản mới dùng overlay chung: `lumi-t23n-nor8-full-shared-login.bin`,
**8,388,608 bytes**, build trong 01:22. Đã kiểm tra passwd/shadow trong SquashFS
khớp source chung, shadow mode 0600 root:root, không Majestic/EULA, toàn bộ offset
và padding full image đúng. Đã kiểm tra hash khớp mật khẩu và chốt từ chối Majestic.
Chưa thử phần cứng; các dòng chip khác chưa rebuild trong lần thay đổi này.
SHA256: `8ab248bbd1bf9428d21df169aef86f5978a2b21c126a32f830eefbea5cf9d305`.
