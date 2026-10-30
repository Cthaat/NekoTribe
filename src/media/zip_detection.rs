//! Bounded ZIP classification. The archive is never extracted.
use crate::storage::media_type_selection::DetectedType;
use std::io::{self, Read, Seek, SeekFrom};

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid ZIP")
}
fn u16le(b: &[u8]) -> u16 {
    u16::from_le_bytes([b[0], b[1]])
}
fn u32le(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}
fn detected(ext: &str, mime: &str) -> DetectedType {
    DetectedType {
        ext: ext.into(),
        mime: mime.into(),
    }
}

struct Entry {
    header: u64,
    data: u64,
    compressed: u64,
    size: u64,
    crc: u32,
    method: u16,
    name: Vec<u8>,
}

pub fn inspect(mut file: std::fs::File) -> io::Result<DetectedType> {
    let size = file.metadata()?.len();
    if !(22..=500 << 20).contains(&size) {
        return Err(invalid());
    }
    let tail_len = size.min(22 + 65535) as usize;
    file.seek(SeekFrom::End(-(tail_len as i64)))?;
    let mut tail = vec![0; tail_len];
    file.read_exact(&mut tail)?;
    let pos = (0..=tail_len - 22)
        .rev()
        .find(|&p| {
            &tail[p..p + 4] == b"PK\x05\x06" && p + 22 + u16le(&tail[p + 20..]) as usize == tail_len
        })
        .ok_or_else(invalid)?;
    let end = &tail[pos..];
    let entries = u16le(&end[10..]) as usize;
    let dir_size = u32le(&end[12..]) as u64;
    let dir_offset = u32le(&end[16..]) as u64;
    if u16le(&end[4..]) != 0
        || u16le(&end[6..]) != 0
        || u16le(&end[8..]) as usize != entries
        || entries == 65535
        || entries > 10_000
        || dir_size > 4 << 20
        || dir_offset.checked_add(dir_size) != Some(size - tail_len as u64 + pos as u64)
    {
        return Err(invalid());
    }
    let mut archive = zip::ZipArchive::new(file.try_clone()?).map_err(|_| invalid())?;
    if archive.len() != entries {
        return Err(invalid());
    }
    let mut items = Vec::with_capacity(entries);
    for i in 0..entries {
        let entry = archive.by_index_raw(i).map_err(|_| invalid())?;
        if entry.encrypted()
            || entry.compressed_size() > u32::MAX as u64
            || entry.size() > u32::MAX as u64
        {
            return Err(invalid());
        }
        items.push(Entry {
            header: entry.header_start(),
            data: entry.data_start(),
            compressed: entry.compressed_size(),
            size: entry.size(),
            crc: entry.crc32(),
            method: match entry.compression() {
                zip::CompressionMethod::Stored => 0,
                zip::CompressionMethod::Deflated => 8,
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::Unsupported,
                        "ZIP compression unavailable",
                    ))
                }
            },
            name: entry.name_raw().to_vec(),
        });
    }
    items.sort_by_key(|e| e.header);
    let mut position = 0u64;
    for entry in &items {
        if entry.header != position || position.checked_add(30).is_none_or(|n| n > dir_offset) {
            return Err(invalid());
        }
        file.seek(SeekFrom::Start(position))?;
        let mut header = [0; 30];
        file.read_exact(&mut header)?;
        if &header[..4] != b"PK\x03\x04" {
            return Err(invalid());
        }
        let flags = u16le(&header[6..]);
        if flags & 1 != 0 || u16le(&header[8..]) != entry.method {
            return Err(invalid());
        }
        let name_len = u16le(&header[26..]) as u64;
        let extra_len = u16le(&header[28..]) as u64;
        if position + 30 + name_len + extra_len != entry.data {
            return Err(invalid());
        }
        let mut name = vec![0; name_len as usize];
        file.read_exact(&mut name)?;
        if name != entry.name {
            return Err(invalid());
        }
        position = entry
            .data
            .checked_add(entry.compressed)
            .filter(|n| *n <= dir_offset)
            .ok_or_else(invalid)?;
        if flags & 8 == 0 {
            if u32le(&header[14..]) != entry.crc
                || u32le(&header[18..]) as u64 != entry.compressed
                || u32le(&header[22..]) as u64 != entry.size
            {
                return Err(invalid());
            }
        } else {
            file.seek(SeekFrom::Start(position))?;
            let mut first = [0; 4];
            file.read_exact(&mut first)?;
            let mut desc = [0; 12];
            if &first == b"PK\x07\x08" {
                file.read_exact(&mut desc)?;
                position += 16;
            } else {
                desc[..4].copy_from_slice(&first);
                file.read_exact(&mut desc[4..])?;
                position += 12;
            }
            if position > dir_offset
                || u32le(&desc) != entry.crc
                || u32le(&desc[4..]) as u64 != entry.compressed
                || u32le(&desc[8..]) as u64 != entry.size
            {
                return Err(invalid());
            }
        }
    }
    if position != dir_offset {
        return Err(invalid());
    }
    for entry in &items {
        let name = std::str::from_utf8(&entry.name).map_err(|_| invalid())?;
        if name == "META-INF/mozilla.rsa" {
            return Ok(detected("xpi", "application/x-xpinstall"));
        }
        if name == "META-INF/MANIFEST.MF" {
            return Ok(detected("jar", "application/java-archive"));
        }
        if name.starts_with("classes")
            && name.ends_with(".dex")
            && name[7..name.len() - 4].bytes().all(|b| b.is_ascii_digit())
        {
            return Ok(detected("apk", "application/vnd.android.package-archive"));
        }
        if name == "mimetype" || name == "[Content_Types].xml" {
            if entry.compressed > 1 << 20 || entry.size > 1 << 20 {
                return Err(invalid());
            }
            let mut inner = archive.by_name(name).map_err(|_| invalid())?;
            let mut data = Vec::new();
            (&mut inner).take((1 << 20) + 1).read_to_end(&mut data)?;
            if data.len() > 1 << 20 {
                return Err(invalid());
            }
            let text = std::str::from_utf8(&data).map_err(|_| invalid())?;
            let mime = if name == "mimetype" {
                text.trim().to_lowercase()
            } else if let Some(pos) = text.find(".main+xml\"") {
                text[..pos].rsplit('"').next().unwrap_or("").to_lowercase()
            } else {
                String::new()
            };
            let ext = match mime.as_str() {
                "application/vnd.oasis.opendocument.text" => "odt",
                "application/vnd.oasis.opendocument.spreadsheet" => "ods",
                "application/vnd.oasis.opendocument.presentation" => "odp",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
                "application/vnd.openxmlformats-officedocument.presentationml.presentation" => {
                    "pptx"
                }
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::Unsupported,
                        "unrecognized ZIP metadata",
                    ))
                }
            };
            return Ok(detected(ext, &mime));
        }
    }
    Ok(detected("zip", "application/zip"))
}
