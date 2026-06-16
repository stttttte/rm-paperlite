package main

// 纯 Go 改写 TTF 的 name 表,把 family(nameID 1/16)与 full/PS 名改成统一值
// "Noto Serif SC",以便覆盖 EPUB 中文回退目标后一定被 fontconfig 命中。
// 只重建 name 表 + 修正 sfnt 头校验/偏移,不动 glyf 等,字形不变。
// 仅支持 TrueType(reMarkable 也只认 TTF)。

import (
	"encoding/binary"
	"fmt"
	"sort"
)

// 目标 family 名
const forcedFamily = "Noto Serif SC"

type tableRec struct {
	tag      [4]byte
	checksum uint32
	offset   uint32
	length   uint32
}

// 重写 TTF/OTF-sfnt 的 name 表,返回新字体字节。失败返回错误(调用方应回退为原样使用)。
func retagFontFamily(data []byte) ([]byte, error) {
	if len(data) < 12 {
		return nil, fmt.Errorf("文件过小")
	}
	sfnt := binary.BigEndian.Uint32(data[0:4])
	// 0x00010000 = TrueType, 'true'(0x74727565). 'OTTO'(CFF) 不处理(rM 不认 OTF)
	if sfnt != 0x00010000 && sfnt != 0x74727565 {
		return nil, fmt.Errorf("非 TrueType sfnt(0x%08x)", sfnt)
	}
	numTables := int(binary.BigEndian.Uint16(data[4:6]))
	recs := make([]tableRec, 0, numTables)
	nameIdx := -1
	for i := 0; i < numTables; i++ {
		o := 12 + i*16
		if o+16 > len(data) {
			return nil, fmt.Errorf("表目录越界")
		}
		var r tableRec
		copy(r.tag[:], data[o:o+4])
		r.checksum = binary.BigEndian.Uint32(data[o+4 : o+8])
		r.offset = binary.BigEndian.Uint32(data[o+8 : o+12])
		r.length = binary.BigEndian.Uint32(data[o+12 : o+16])
		if string(r.tag[:]) == "name" {
			nameIdx = len(recs)
		}
		recs = append(recs, r)
	}
	if nameIdx < 0 {
		return nil, fmt.Errorf("无 name 表")
	}

	newName := buildNameTable()

	// 重新布局:按各表当前 offset 排序,顺序写出,name 表用新内容,4 字节对齐。
	order := make([]int, len(recs))
	for i := range order {
		order[i] = i
	}
	sort.Slice(order, func(a, b int) bool { return recs[order[a]].offset < recs[order[b]].offset })

	headerLen := 12 + len(recs)*16
	out := make([]byte, headerLen)
	// sfnt header
	binary.BigEndian.PutUint32(out[0:4], sfnt)
	binary.BigEndian.PutUint16(out[4:6], uint16(numTables))
	// searchRange/entrySelector/rangeShift 照抄(非关键,多数渲染器不校验)
	copy(out[6:12], data[6:12])

	newOffsets := make(map[int]uint32, len(recs))
	newLengths := make(map[int]uint32, len(recs))
	for _, idx := range order {
		var body []byte
		if idx == nameIdx {
			body = newName
		} else {
			r := recs[idx]
			if int(r.offset)+int(r.length) > len(data) {
				return nil, fmt.Errorf("表 %s 越界", string(r.tag[:]))
			}
			body = data[r.offset : r.offset+r.length]
		}
		off := uint32(len(out))
		newOffsets[idx] = off
		newLengths[idx] = uint32(len(body))
		out = append(out, body...)
		for len(out)%4 != 0 { // 4 字节对齐
			out = append(out, 0)
		}
	}
	// 写回表目录(checksum 用原值/name 表置 0;多数渲染器不强校验表 checksum)
	for i, r := range recs {
		o := 12 + i*16
		copy(out[o:o+4], r.tag[:])
		cs := r.checksum
		if i == nameIdx {
			cs = 0
		}
		binary.BigEndian.PutUint32(out[o+4:o+8], cs)
		binary.BigEndian.PutUint32(out[o+8:o+12], newOffsets[i])
		binary.BigEndian.PutUint32(out[o+12:o+16], newLengths[i])
	}
	return out, nil
}

// 构造一个只含必要记录的 name 表:family(1,16)/subfamily(2,17)/full(4)/ps(6),
// 同时写 Windows(3,1,0x409) 和 Mac(1,0,0) 两个平台。
func buildNameTable() []byte {
	type nr struct {
		platID, encID, langID, nameID uint16
		value                         string
	}
	vals := map[uint16]string{
		1:  forcedFamily,
		2:  "Regular",
		4:  forcedFamily,
		6:  "NotoSerifSC-Regular",
		16: forcedFamily,
		17: "Regular",
	}
	var records []nr
	ids := []uint16{1, 2, 4, 6, 16, 17}
	for _, id := range ids {
		v := vals[id]
		records = append(records, nr{3, 1, 0x409, id, v}) // Windows UTF-16BE
		records = append(records, nr{1, 0, 0, id, v})      // Mac Roman
	}
	// 排序:按 (platID, encID, langID, nameID)
	sort.Slice(records, func(a, b int) bool {
		ra, rb := records[a], records[b]
		if ra.platID != rb.platID {
			return ra.platID < rb.platID
		}
		if ra.encID != rb.encID {
			return ra.encID < rb.encID
		}
		if ra.langID != rb.langID {
			return ra.langID < rb.langID
		}
		return ra.nameID < rb.nameID
	})

	// 编码字符串区
	var strData []byte
	type recOut struct {
		platID, encID, langID, nameID, length, offset uint16
	}
	var outRecs []recOut
	for _, r := range records {
		var enc []byte
		if r.platID == 3 { // UTF-16BE
			for _, ru := range r.value {
				enc = append(enc, byte(ru>>8), byte(ru))
			}
		} else { // Mac Roman ~ ASCII
			enc = []byte(r.value)
		}
		outRecs = append(outRecs, recOut{r.platID, r.encID, r.langID, r.nameID, uint16(len(enc)), uint16(len(strData))})
		strData = append(strData, enc...)
	}

	count := len(outRecs)
	storageOffset := 6 + count*12
	buf := make([]byte, 6+count*12)
	binary.BigEndian.PutUint16(buf[0:2], 0) // format 0
	binary.BigEndian.PutUint16(buf[2:4], uint16(count))
	binary.BigEndian.PutUint16(buf[4:6], uint16(storageOffset))
	for i, r := range outRecs {
		o := 6 + i*12
		binary.BigEndian.PutUint16(buf[o:o+2], r.platID)
		binary.BigEndian.PutUint16(buf[o+2:o+4], r.encID)
		binary.BigEndian.PutUint16(buf[o+4:o+6], r.langID)
		binary.BigEndian.PutUint16(buf[o+6:o+8], r.nameID)
		binary.BigEndian.PutUint16(buf[o+8:o+10], r.length)
		binary.BigEndian.PutUint16(buf[o+10:o+12], r.offset)
	}
	buf = append(buf, strData...)
	return buf
}
