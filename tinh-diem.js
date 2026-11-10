/* Nikki Diary — bộ tính điểm (viết mới).
   Điểm món dựa trên điểm chữ (C, B, A, S, SS) của 10 phong cách, quy đổi sang số ước tính.
   Luật trừ điểm trang sức theo Love Nikki Wiki, trang "Styling Battle" (CC BY-SA 3.0). */
(function (goc) {
  'use strict';

  // Điểm chữ → số: mỗi bậc gấp đôi bậc dưới (X = SS)
  var BAC = { C: 1, B: 2, A: 4, S: 8, X: 16 };

  // Cỡ từng ô so với Tóc (ước tính, chỉnh dần theo điểm đo trong game)
  var CO_O = {
    'Tóc': 1, 'Đầm': 2, 'Áo khoác': 0.6, 'Áo': 1, 'Quần': 1, 'Vớ': 0.6, 'Phụ kiện chân': 0.6,
    'Giày': 0.8, 'Trang điểm': 0.4
  };
  var CO_TRANG_SUC = 0.4;

  // Đổi đơn vị nội bộ ra điểm hiển thị gần với điểm trong game (ước tính)
  var HE_SO_HIEN_THI = 9;

  // Số trang sức đeo → hệ số nhân cho phần trang sức (Love Nikki Wiki)
  var TRU_TRANG_SUC = { 4: 0.95, 5: 0.9, 6: 0.825, 7: 0.75, 8: 0.7, 9: 0.65, 10: 0.6, 11: 0.55, 12: 0.51, 13: 0.475, 14: 0.45, 15: 0.425 };
  function heSoTrangSuc(soMon) {
    if (soMon <= 3) return 1;
    return TRU_TRANG_SUC[soMon] || 0.4;
  }

  /* Dựng kho món từ du-lieu.json.
     Mỗi món: { ma, ten, o (tên ô), trangSuc (true/false), diem: [10 số] } */
  function taoKho(duLieu) {
    var kho = { pc: duLieu.pc, o: duLieu.o, mon: {}, theoO: {}, khuThiDau: duLieu.khu_thi_dau };
    duLieu.mon.forEach(function (r) {
      var o = duLieu.o[r[2]];
      var diem = [];
      for (var k = 0; k < 10; k++) diem.push(BAC[r[3].charAt(k)] || 0);
      var m = { ma: r[0], ten: r[1], o: o, trangSuc: r[2] >= duLieu.so_do_chinh, diem: diem, chu: r[3] };
      kho.mon[m.ma] = m;
      (kho.theoO[o] = kho.theoO[o] || []).push(m);
    });
    return kho;
  }

  // Điểm một món với bộ trọng số (10 số, phong cách ải không cần = 0)
  function chamMon(mon, trongSo) {
    var tong = 0;
    for (var k = 0; k < 10; k++) tong += mon.diem[k] * trongSo[k];
    return tong * (mon.trangSuc ? CO_TRANG_SUC : (CO_O[mon.o] || 1));
  }

  /* Phối bộ điểm cao nhất.
     dsMa: danh sách mã món được dùng (null = toàn bộ kho)
     tuyChon.itTrangSuc: true = được bỏ bớt trang sức nếu như vậy điểm cao hơn (mặc định true) */
  function phoiBo(kho, trongSo, dsMa, tuyChon) {
    tuyChon = tuyChon || {};
    var duocDung = null;
    if (dsMa) { duocDung = {}; dsMa.forEach(function (m) { duocDung[m] = true; }); }

    // 1. Món tốt nhất của từng ô (+ danh sách xếp hạng để đổi món)
    var tot = {}, xepHang = {};
    Object.keys(kho.theoO).forEach(function (o) {
      var ds = [];
      kho.theoO[o].forEach(function (m) {
        if (duocDung && !duocDung[m.ma]) return;
        var d = chamMon(m, trongSo);
        if (d > 0) ds.push({ mon: m, diem: d });
      });
      ds.sort(function (a, b) { return b.diem - a.diem; });
      if (ds.length) { tot[o] = ds[0]; xepHang[o] = ds; }
    });

    // 2. Đầm hay Áo + Quần; Hai tay hay Tay phải + Tay trái
    chonMot(tot, ['Đầm'], ['Áo', 'Quần']);
    chonMot(tot, ['Hai tay'], ['Tay phải', 'Tay trái']);

    // 3. Trang sức: xếp từ cao xuống, chọn số món cho tổng (sau khi trừ) cao nhất
    var dsTs = Object.keys(tot).filter(function (o) { return tot[o].mon.trangSuc; })
      .sort(function (a, b) { return tot[b].diem - tot[a].diem; });
    var giu = dsTs.length, tongTs = 0;
    if (tuyChon.itTrangSuc !== false) {
      var tot1 = -1, cong = 0;
      for (var n = 0; n <= dsTs.length; n++) {
        if (n > 0) cong += tot[dsTs[n - 1]].diem;
        var t = cong * heSoTrangSuc(n);
        if (t > tot1) { tot1 = t; giu = n; }
      }
    }
    dsTs.slice(giu).forEach(function (o) { delete tot[o]; });
    dsTs.slice(0, giu).forEach(function (o) { tongTs += tot[o].diem; });

    var doChinh = 0;
    Object.keys(tot).forEach(function (o) { if (!tot[o].mon.trangSuc) doChinh += tot[o].diem; });
    var heSo = heSoTrangSuc(giu);
    return {
      bo: tot,                      // { tên ô: { mon, diem } }
      xepHang: xepHang,             // { tên ô: [{ mon, diem }, ...] } để đổi món
      soTrangSuc: giu,
      heSoTrangSuc: heSo,
      tong: Math.round((doChinh + tongTs * heSo) * HE_SO_HIEN_THI)  // điểm ước tính
    };
  }

  /* Tính lại điểm một bộ đã chọn sẵn (sau khi người dùng đổi món).
     bo: { tên ô: món }. Trả về { tong, soTrangSuc, heSoTrangSuc } */
  function chamBo(trongSo, bo) {
    var doChinh = 0, ts = 0, n = 0;
    Object.keys(bo).forEach(function (o) {
      var m = bo[o]; if (!m) return;
      var d = chamMon(m, trongSo);
      if (m.trangSuc) { ts += d; n++; } else doChinh += d;
    });
    var heSo = heSoTrangSuc(n);
    return { tong: Math.round((doChinh + ts * heSo) * HE_SO_HIEN_THI), soTrangSuc: n, heSoTrangSuc: heSo };
  }

  // Điểm một món đổi ra thang hiển thị (để so các món với nhau)
  function diemHienThi(mon, trongSo) { return Math.round(chamMon(mon, trongSo) * HE_SO_HIEN_THI); }

  // Giữ nhóm có tổng điểm cao hơn, bỏ nhóm còn lại
  function chonMot(tot, nhomA, nhomB) {
    function cong(ds) { return ds.reduce(function (s, o) { return s + (tot[o] ? tot[o].diem : 0); }, 0); }
    var bo = cong(nhomA) >= cong(nhomB) ? nhomB : nhomA;
    bo.forEach(function (o) { delete tot[o]; });
  }

  /* Đọc file tủ đồ lấy từ máy (clothes_date…) theo định dạng file của game: base64 → RC4 → chuỗi {[mã]=…}.
     Trả về danh sách mã món. */
  function docTuDo(chuoi) {
    var nhiPhan = atob(String(chuoi).replace(/\s+/g, ''));
    var khoa = 'ELPSsYasdaKONGROO', s = [], i, j = 0, x;
    for (i = 0; i < 256; i++) s[i] = i;
    for (i = 0; i < 256; i++) {
      j = (j + s[i] + khoa.charCodeAt(i % khoa.length)) & 255;
      x = s[i]; s[i] = s[j]; s[j] = x;
    }
    var ra = '', a = 0, b = 0;
    for (var k = 0; k < nhiPhan.length; k++) {
      a = (a + 1) & 255; b = (b + s[a]) & 255;
      x = s[a]; s[a] = s[b]; s[b] = x;
      ra += String.fromCharCode(nhiPhan.charCodeAt(k) ^ s[(s[a] + s[b]) & 255]);
    }
    var gap = {}, ds = [], m, re = /\[(\d+)\]/g;
    while ((m = re.exec(ra))) if (!gap[m[1]]) { gap[m[1]] = 1; ds.push(+m[1]); }
    return ds;
  }

  var TinhDiem = { taoKho: taoKho, chamMon: chamMon, chamBo: chamBo, diemHienThi: diemHienThi, phoiBo: phoiBo, heSoTrangSuc: heSoTrangSuc, docTuDo: docTuDo };
  if (typeof module !== 'undefined' && module.exports) module.exports = TinhDiem;
  else goc.TinhDiem = TinhDiem;
})(this);
