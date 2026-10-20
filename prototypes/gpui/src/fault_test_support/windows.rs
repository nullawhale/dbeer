//! Native owner-only creation and verification, without changing any existing
//! directory ACL. Every FFI buffer is bounded and retained through its use.
use super::Result;
use std::{ffi::c_void, mem, os::windows::ffi::OsStrExt, path::Path, ptr};

type Handle = *mut c_void;
#[repr(C)]
struct SecurityAttributes {
    length: u32,
    descriptor: Handle,
    inherit: i32,
}
#[repr(C)]
struct TokenUser {
    sid: Handle,
    attributes: u32,
}
#[repr(C)]
struct Acl {
    revision: u8,
    reserved: u8,
    size: u16,
    count: u16,
    reserved2: u16,
}
#[repr(C)]
struct AllowAce {
    kind: u8,
    flags: u8,
    size: u16,
    mask: u32,
    sid_start: u32,
}
#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
    fn GetTokenInformation(
        token: Handle,
        class: u32,
        data: Handle,
        length: u32,
        needed: *mut u32,
    ) -> i32;
    fn GetSecurityInfo(
        handle: Handle,
        kind: u32,
        information: u32,
        owner: *mut Handle,
        group: *mut Handle,
        dacl: *mut *mut Acl,
        sacl: *mut Handle,
        descriptor: *mut Handle,
    ) -> u32;
    fn EqualSid(first: Handle, second: Handle) -> i32;
    fn GetAce(acl: *mut Acl, index: u32, ace: *mut Handle) -> i32;
    fn IsValidSid(sid: Handle) -> i32;
    fn GetLengthSid(sid: Handle) -> u32;
    fn ConvertSidToStringSidW(sid: Handle, text: *mut *mut u16) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut Handle,
        size: *mut u32,
    ) -> i32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> Handle;
    fn CloseHandle(handle: Handle) -> i32;
    fn LocalFree(memory: Handle) -> Handle;
    fn CreateDirectoryW(path: *const u16, attributes: *const SecurityAttributes) -> i32;
}
struct OwnedHandle(Handle);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
struct LocalMemory(Handle);
impl Drop for LocalMemory {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}
// usize storage provides native pointer alignment for TOKEN_USER.
struct User(Vec<usize>);
impl User {
    fn current() -> Result<Self> {
        let mut token = ptr::null_mut();
        if unsafe { OpenProcessToken(GetCurrentProcess(), 8, &mut token) } == 0 {
            return Err("Cannot identify the native fixture user.");
        }
        let token = OwnedHandle(token);
        let mut needed = 0;
        unsafe {
            GetTokenInformation(token.0, 1, ptr::null_mut(), 0, &mut needed);
        }
        if needed < mem::size_of::<TokenUser>() as u32 || needed > 64 * 1024 {
            return Err("The native fixture user token is invalid.");
        }
        let mut data = vec![0usize; (needed as usize).div_ceil(mem::size_of::<usize>())];
        if unsafe { GetTokenInformation(token.0, 1, data.as_mut_ptr().cast(), needed, &mut needed) }
            == 0
        {
            return Err("Cannot read the native fixture user token.");
        }
        let user = Self(data);
        if unsafe { IsValidSid(user.sid()) } == 0 {
            return Err("The native fixture user SID is invalid.");
        }
        Ok(user)
    }
    fn sid(&self) -> Handle {
        unsafe { (*self.0.as_ptr().cast::<TokenUser>()).sid }
    }
}
fn wide(path: &Path) -> Result<Vec<u16>> {
    let mut value: Vec<u16> = path.as_os_str().encode_wide().collect();
    if value.contains(&0) {
        return Err("The native fixture path is invalid.");
    }
    value.push(0);
    Ok(value)
}

pub(super) fn create_directory(path: &Path) -> Result<()> {
    let user = User::current()?;
    let mut sid_text = ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(user.sid(), &mut sid_text) } == 0 {
        return Err("Cannot encode the native fixture user SID.");
    }
    let sid_text_owner = LocalMemory(sid_text.cast());
    let mut length = 0;
    // A valid Windows SID string fits well inside this bound.
    while length < 256 && unsafe { *sid_text.add(length) } != 0 {
        length += 1;
    }
    if length == 256 {
        return Err("The native fixture user SID exceeded its bound.");
    }
    let sid = String::from_utf16(unsafe { std::slice::from_raw_parts(sid_text, length) })
        .map_err(|_| "Cannot encode the native fixture user SID.")?;
    drop(sid_text_owner);
    // Owner plus a protected, inheritable current-user-only full-access DACL.
    // SECURITY_ATTRIBUTES supplies it at creation, before any file is written.
    let sddl: Vec<u16> = format!("O:{sid}D:P(A;OICI;FA;;;{sid})\0")
        .encode_utf16()
        .collect();
    let mut descriptor = ptr::null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err("Cannot prepare the private native fixture DACL.");
    }
    let descriptor = LocalMemory(descriptor);
    let attributes = SecurityAttributes {
        length: mem::size_of::<SecurityAttributes>() as u32,
        descriptor: descriptor.0,
        inherit: 0,
    };
    if unsafe { CreateDirectoryW(wide(path)?.as_ptr(), &attributes) } == 0 {
        return Err("Cannot reserve the private native fixture directory.");
    }
    private(path)
}

pub(super) fn private(path: &Path) -> Result<()> {
    use std::os::windows::{fs::OpenOptionsExt, io::AsRawHandle};
    let user = User::current()?;
    // READ_CONTROL + FILE_READ_ATTRIBUTES; open the exact object, deny delete
    // sharing during inspection, and never follow a reparse point.
    let file = std::fs::OpenOptions::new()
        .access_mode(0x00020080)
        .share_mode(3)
        .custom_flags(0x02200000)
        .open(path)
        .map_err(|_| "Cannot inspect the native fixture DACL.")?;
    let mut owner = ptr::null_mut();
    let mut acl = ptr::null_mut();
    let mut descriptor = ptr::null_mut();
    if unsafe {
        GetSecurityInfo(
            file.as_raw_handle(),
            1,
            1 | 4,
            &mut owner,
            ptr::null_mut(),
            &mut acl,
            ptr::null_mut(),
            &mut descriptor,
        )
    } != 0
    {
        return Err("Cannot inspect the native fixture DACL.");
    }
    let _descriptor = LocalMemory(descriptor);
    if owner.is_null()
        || acl.is_null()
        || unsafe { EqualSid(owner, user.sid()) } == 0
        || unsafe { (*acl).count } != 1
    {
        return Err("Native fixture paths require a current-user-only DACL and owner.");
    }
    let mut ace = ptr::null_mut();
    if unsafe { GetAce(acl, 0, &mut ace) } == 0 || ace.is_null() {
        return Err("The native fixture DACL is invalid.");
    }
    let allow = unsafe { &*ace.cast::<AllowAce>() };
    let sid = unsafe { ace.cast::<u8>().add(8).cast::<c_void>() };
    if allow.kind != 0
        || allow.flags & 0x08 != 0
        || allow.size < 12
        || allow.mask & 0x001f01ff != 0x001f01ff
        || unsafe { IsValidSid(sid) } == 0
        || unsafe { GetLengthSid(sid) } + 8 > u32::from(allow.size)
        || unsafe { EqualSid(sid, user.sid()) } == 0
    {
        return Err("Native fixture paths require a current-user-only full-access DACL.");
    }
    Ok(())
}
