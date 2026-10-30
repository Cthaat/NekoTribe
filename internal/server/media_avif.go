package server

import "encoding/binary"

// avifBox describes a validated ISO BMFF box inside the bounded prefix.
type avifBox struct {
	kind string
	body []byte
}

func avifBoxes(data []byte) ([]avifBox, bool) {
	boxes := make([]avifBox, 0)
	for len(data) > 0 {
		if len(boxes) >= 1024 || len(data) < 8 {
			return nil, false
		}
		size := uint64(binary.BigEndian.Uint32(data[:4]))
		header := uint64(8)
		if size == 1 {
			if len(data) < 16 {
				return nil, false
			}
			size = binary.BigEndian.Uint64(data[8:16])
			header = 16
		} else if size == 0 {
			size = uint64(len(data))
		}
		if size < header || size > uint64(len(data)) {
			return nil, false
		}
		boxes = append(boxes, avifBox{kind: string(data[4:8]), body: data[header:size]})
		data = data[size:]
	}
	return boxes, true
}

func avifDimensions(data []byte) (uint32, uint32, bool) {
	var meta []byte
	for boxes := 0; len(data) >= 8 && boxes < 1024; boxes++ {
		size, header := uint64(binary.BigEndian.Uint32(data[:4])), uint64(8)
		if size == 1 {
			if len(data) < 16 {
				return 0, 0, false
			}
			size, header = binary.BigEndian.Uint64(data[8:16]), 16
		} else if size == 0 {
			size = uint64(len(data))
		}
		if size < header || size > uint64(len(data)) {
			return 0, 0, false
		}
		if string(data[4:8]) == "meta" {
			if size < header+4 {
				return 0, 0, false
			}
			meta = data[header+4 : size]
			break
		}
		data = data[size:]
	}
	if meta == nil {
		return 0, 0, false
	}
	children, ok := avifBoxes(meta)
	if !ok {
		return 0, 0, false
	}
	var primary uint32
	var havePrimary bool
	var iprp []byte
	for _, box := range children {
		switch box.kind {
		case "pitm":
			if havePrimary || len(box.body) < 6 {
				return 0, 0, false
			}
			switch box.body[0] {
			case 0:
				primary = uint32(binary.BigEndian.Uint16(box.body[4:6]))
			case 1:
				if len(box.body) < 8 {
					return 0, 0, false
				}
				primary = binary.BigEndian.Uint32(box.body[4:8])
			default:
				return 0, 0, false
			}
			havePrimary = true
		case "iprp":
			if iprp != nil {
				return 0, 0, false
			}
			iprp = box.body
		}
	}
	if !havePrimary || iprp == nil {
		return 0, 0, false
	}
	properties, ok := avifBoxes(iprp)
	if !ok {
		return 0, 0, false
	}
	var items []avifBox
	var associations []byte
	for _, box := range properties {
		switch box.kind {
		case "ipco":
			if items != nil {
				return 0, 0, false
			}
			items, ok = avifBoxes(box.body)
			if !ok {
				return 0, 0, false
			}
		case "ipma":
			if associations != nil {
				return 0, 0, false
			}
			associations = box.body
		}
	}
	if len(associations) < 8 || items == nil {
		return 0, 0, false
	}
	version := associations[0]
	if version > 1 {
		return 0, 0, false
	}
	wide := associations[3]&1 != 0
	count := binary.BigEndian.Uint32(associations[4:8])
	if count > 4096 {
		return 0, 0, false
	}
	remaining := associations[8:]
	var width, height uint32
	foundPrimary, foundSize := false, false
	for i := uint32(0); i < count; i++ {
		idLen := 2
		if version == 1 {
			idLen = 4
		}
		if len(remaining) < idLen+1 {
			return 0, 0, false
		}
		var id uint32
		if version == 1 {
			id = binary.BigEndian.Uint32(remaining[:4])
		} else {
			id = uint32(binary.BigEndian.Uint16(remaining[:2]))
		}
		n := int(remaining[idLen])
		remaining = remaining[idLen+1:]
		if id == primary {
			if foundPrimary {
				return 0, 0, false
			}
			foundPrimary = true
		}
		for j := 0; j < n; j++ {
			var index uint16
			if wide {
				if len(remaining) < 2 {
					return 0, 0, false
				}
				index = binary.BigEndian.Uint16(remaining[:2]) & 0x7fff
				remaining = remaining[2:]
			} else {
				if len(remaining) < 1 {
					return 0, 0, false
				}
				index = uint16(remaining[0] & 0x7f)
				remaining = remaining[1:]
			}
			if id != primary || index == 0 {
				continue
			}
			if int(index) > len(items) {
				return 0, 0, false
			}
			property := items[index-1]
			if property.kind != "ispe" {
				continue
			}
			if foundSize || len(property.body) < 12 || property.body[0] != 0 {
				return 0, 0, false
			}
			width = binary.BigEndian.Uint32(property.body[4:8])
			height = binary.BigEndian.Uint32(property.body[8:12])
			foundSize = true
		}
	}
	return width, height, foundPrimary && foundSize && width > 0 && height > 0
}
