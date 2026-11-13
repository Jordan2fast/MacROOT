# Credits

MacROOT stands on the work of the Hackintosh community. None of these projects endorse MacROOT, and MacROOT isn't affiliated with Apple or any of them. The same list is in the app under **About & Credits**.

## Used by MacROOT at run time
| Project | Author | Used for |
|---|---|---|
| [OpCore Simplify](https://github.com/lzhoang2801/OpCore-Simplify) | lzhoang2801 | Backend of the Upgrade Assistant: its kext dataset (per-macOS compatibility, requirements, download sources) and its generated EFIs. BSD 3-Clause. MacROOT downloads its data at run time and does not redistribute its code. |
| [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) | Acidanthera | OpenCore, `ocvalidate`, `macserial`, `Sample.plist` |
| [Lilu, VirtualSMC, WhateverGreen, AppleALC, NVMeFix, CPUFriend, RestrictEvents, HibernationFixup, BrcmPatchRAM, AirportBrcmFixup, CryptexFixup, FeatureUnlock, VoodooPS2](https://github.com/acidanthera) | Acidanthera | Kexts MacROOT checks and updates |
| [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher) | Dortania | Source of kexts such as AMFIPass and IO80211FamilyLegacy referenced by OpCore Simplify's dataset |
| Other kext authors in OpCore Simplify's dataset | Many | Including VoodooI2C, Mieze, ChefKissInc, DexterSLamb, lshbluesky, USBToolBox, 1Revenger1, 0xFireWolf |
| [Claude API](https://www.anthropic.com) | Anthropic | Optional AI kext generator (your own API key) |

## Inspiration
| Project | Author | What it inspired |
|---|---|---|
| [OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/) | Dortania | Nearly every rule, quirk and checklist; the iServices guidance |
| [Hackintool](https://github.com/headkaze/Hackintool) | headkaze | PCI, USB and SMBIOS tooling |
| [MountEFI, ProperTree, USBMap, OCConfigCompare, SSDTTime](https://github.com/corpnewt) | CorpNewt | EFI mounter, plist editor, USB mapping, config comparison, ACPI work |
| [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) | CorpNewt | The SMBIOS flow of `iservices-helper.sh`; MacROOT generates with `macserial` directly, the engine GenSMBIOS also uses |
| [OpenCore Auxiliary Tools](https://github.com/ic005k/OCAuxiliaryTools) | ic005k | A full GUI config editor |
| [USBToolBox](https://github.com/USBToolBox) | USBToolBox | USB mapping |
| [Hardware Sniffer](https://github.com/lzhoang2801/Hardware-Sniffer) | lzhoang2801 | The hardware report OpCore Simplify consumes |

Running macOS on non-Apple hardware falls outside Apple's macOS licence terms. Use MacROOT at your own risk.
