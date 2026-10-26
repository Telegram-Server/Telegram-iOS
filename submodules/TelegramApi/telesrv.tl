// telesrv-only RPCs, see TELESRV_EXTENSIONS.md. Never sent to official servers.

---functions---

telesrv.getLoginPassword#e35bc783 flags:# phone_number:string = account.Password;
telesrv.signInWithPassword#b57ee87d flags:# phone_number:string password:InputCheckPasswordSRP = auth.Authorization;
telesrv.signUpWithPassword#e57cf5b6 flags:# phone_number:string first_name:string last_name:string new_settings:account.PasswordInputSettings = auth.Authorization;
telesrv.getMyLoginPassword#70c0eadb flags:# = account.Password;
telesrv.updateLoginPassword#917c32ca flags:# current:InputCheckPasswordSRP new_settings:account.PasswordInputSettings = Bool;
