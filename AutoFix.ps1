# Single-file Deadlock camera repair. Windows PowerShell 5.1 is supported as a bootstrap.
[CmdletBinding()]
param(
 [ValidateSet('Scan','Prepare','Repair','Install','Restore')][string]$Mode='Repair',
 [string]$GamePath,[string]$ToolRoot,[string]$OutputRoot,[string]$CacheRoot,
 [string]$BatchReport,[string[]]$Vpk,[switch]$ForcePortableRuntime,
 [Parameter(DontShow=$true)][string]$InternalParameters
)
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem){throw 'Windows x64 is required.'}
if($InternalParameters){
 $data=Get-Content -LiteralPath $InternalParameters -Raw | ConvertFrom-Json
 foreach($name in @('Mode','GamePath','ToolRoot','OutputRoot','CacheRoot','BatchReport','Vpk')){if($data.PSObject.Properties[$name]){Set-Variable -Name $name -Value $data.$name}}
}
if(-not $CacheRoot){$CacheRoot=Join-Path $env:LOCALAPPDATA 'deadlock-camera-fix'}
$CacheRoot=[IO.Path]::GetFullPath($CacheRoot)
New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
if(-not $ToolRoot){$ToolRoot=Join-Path $CacheRoot 'tools'}
if(-not $OutputRoot){$OutputRoot=Join-Path $CacheRoot 'repairs'}
$ToolRoot=[IO.Path]::GetFullPath($ToolRoot);$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
function Download-Checked([string]$Url,[string]$Destination,[string]$Checksum){
 if(-not (Test-Path -LiteralPath $Destination)){
  Write-Host "Downloading $([IO.Path]::GetFileName($Destination)) ..."
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $partial=$Destination+'.partial'
  try{Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $partial;Move-Item -LiteralPath $partial -Destination $Destination -Force}finally{if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial}}
 }
 if((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Checksum){throw "Checksum mismatch: $Destination. Delete this corrupt download and retry."}
}
$compatible=[Environment]::Version.Major -ge 10 -and (Test-Path -LiteralPath (Join-Path $PSHOME 'ref/System.Runtime.dll'))
if(-not $compatible -or ($ForcePortableRuntime -and -not $InternalParameters)){
 if($InternalParameters){throw 'The selected PowerShell runtime is incompatible; .NET 10 and compiler reference assemblies are required.'}
 $pwsh=$null
 if(-not $ForcePortableRuntime){
  $command=Get-Command pwsh -ErrorAction SilentlyContinue
  if($command){
   # EncodedCommand prevents Windows PowerShell 5.1 native-argument quote loss.
   $probe='if([Environment]::Version.Major -ge 10 -and [IO.File]::Exists([IO.Path]::Combine($PSHOME,''ref'',''System.Runtime.dll''))){exit 0}else{exit 1}'
   & $command.Source -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe)))
   if($LASTEXITCODE -eq 0){$pwsh=$command.Source}
  }
 }
 if(-not $pwsh){
  $runtime=Join-Path $CacheRoot 'powershell-7.6.7';$pwsh=Join-Path $runtime 'pwsh.exe'
  if(-not (Test-Path -LiteralPath $pwsh) -or -not (Test-Path -LiteralPath (Join-Path $runtime 'ref/System.Runtime.dll'))){
   $zip=Join-Path $CacheRoot 'powershell-7.6.7.zip'
   Download-Checked 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7-win-x64.zip' $zip 'd2f952ebdbf24386cb8923553aa58e41a846db35a6155ea04c58142a4b16dbb7'
   Expand-Archive -LiteralPath $zip -DestinationPath $runtime -Force
  }
 }
 $parameters=@{Mode=$Mode;GamePath=$GamePath;ToolRoot=$ToolRoot;OutputRoot=$OutputRoot;CacheRoot=$CacheRoot;BatchReport=$BatchReport;Vpk=$Vpk}
 $handoff=Join-Path $CacheRoot ('args-'+[guid]::NewGuid().ToString('N')+'.json')
 try{
  [IO.File]::WriteAllText($handoff,($parameters | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
  & $pwsh -NoProfile -File $PSCommandPath -InternalParameters $handoff
  if($LASTEXITCODE -ne 0){throw "Repair process failed (exit $LASTEXITCODE). See the error above."}
 }finally{if(Test-Path -LiteralPath $handoff){Remove-Item -LiteralPath $handoff}}
 return
}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Resolve-Game([string]$Requested){
 if($Requested){$found=@([IO.Path]::GetFullPath($Requested))}else{
  $steamRoots=@()
  foreach($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')){
   if(Test-Path $key){$reg=Get-ItemProperty $key;$steamRoots+=@($reg.SteamPath,$reg.InstallPath) | Where-Object {$_}}
  }
  $libraries=@($steamRoots)
  foreach($root in ($steamRoots | Select-Object -Unique)){
   $vdf=Join-Path $root 'steamapps/libraryfolders.vdf'
   if(Test-Path -LiteralPath $vdf){foreach($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw),'"path"\s+"([^"]+)"')){$libraries+=$match.Groups[1].Value.Replace('\\','\')}}
  }
  $found=@($libraries | Select-Object -Unique | ForEach-Object {Join-Path $_ 'steamapps/common/Deadlock'} | Where-Object {Test-Path -LiteralPath (Join-Path $_ 'game/citadel/pak01_dir.vpk')})
 }
 if($found.Count -ne 1){throw "Found $($found.Count) Deadlock installations. Supply -GamePath."}
 $resolved=(Resolve-Path -LiteralPath $found[0]).Path
 if(-not (Test-Path -LiteralPath (Join-Path $resolved 'game/citadel/pak01_dir.vpk'))){throw 'Vanilla VPK not found.'}
 return $resolved
}
function Write-Json([string]$Path,$Data){
 $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  $Data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
  if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
 }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp}}
}
function Replace-Mod($Record,[string]$Action){
 if(Get-Process -Name deadlock,citadel -ErrorAction SilentlyContinue){throw 'Exit Deadlock before installing or restoring.'}
 $game=Resolve-Game $Record.game;$addons=Join-Path $game 'game/citadel/addons'
 if($Record.vpk -notmatch '^pak\d+_dir\.vpk$'){throw 'Invalid target VPK name in report.'}
 $target=Join-Path $addons $Record.vpk
 if((Get-Item -LiteralPath $target).LinkType){throw 'Linked VPK targets are unsupported.'}
 $restore=$Action -eq 'Restore'
 $expected=if($restore){$Record.fixedSha256}else{$Record.originalSha256}
 $desired=if($restore){$Record.originalSha256}else{$Record.fixedSha256}
 $artifact=if($restore){$Record.backup}else{$Record.fixed}
 if((Hash $Record.backup) -ne $Record.originalSha256){throw 'Original backup hash mismatch.'}
 if((Hash $artifact) -ne $desired){throw 'Prepared archive or backup hash mismatch.'}
 $actual=Hash $target
 if($actual -eq $desired){return}
 if($actual -ne $expected){throw 'Target changed or moved since preparation; refusing to overwrite.'}
 $temp=Join-Path $addons ('.camera-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{
  Copy-Item -LiteralPath $artifact -Destination $temp
  if((Hash $temp) -ne $desired -or (Hash $target) -ne $expected){throw 'Staged archive or target changed.'}
  if(Get-Process -Name deadlock,citadel -ErrorAction SilentlyContinue){throw 'Deadlock started; exit it before installing.'}
  [IO.File]::Replace($temp,$target,[System.Management.Automation.Language.NullString]::Value)
  if((Hash $target) -ne $desired){throw 'Installed hash mismatch.'}
 }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp}}
}
if($Mode -in @('Install','Restore')){
 if(-not $BatchReport){throw '-BatchReport is required.'}
 if(Get-Process -Name deadlock,citadel -ErrorAction SilentlyContinue){throw 'Exit Deadlock first. Reports and archives were not changed.'}
 $batchPath=(Resolve-Path -LiteralPath $BatchReport).Path;$batch=Get-Content -LiteralPath $batchPath -Raw | ConvertFrom-Json
 if($batch.schema -notin @(1,2)){throw 'Unsupported batch report schema.'}
 foreach($item in $batch.mods){
  if(-not $item.repairReport){continue}
  try{$record=Get-Content -LiteralPath $item.repairReport -Raw | ConvertFrom-Json;Replace-Mod $record $Mode;$item.status=if($Mode -eq 'Restore'){'restored'}else{'installed'};$item.error=$null}catch{$item.status='failed';$item.error=$_.Exception.Message}
  Write-Json $batchPath $batch
 }
 $batch.mods | Select-Object vpk,name,status,error | Format-Table -AutoSize | Out-Host
 Write-Host "Batch report: $batchPath";return
}
$GamePath=Resolve-Game $GamePath
$addons=Join-Path $GamePath 'game/citadel/addons'
if($OutputRoot.StartsWith([IO.Path]::GetFullPath($addons),[StringComparison]::OrdinalIgnoreCase)){throw 'Keep output and backups outside addons.'}
New-Item -ItemType Directory -Path $ToolRoot -Force | Out-Null
# Only the model parsing library and its dependencies are downloaded; no Node or CLI executable.
$packages=@(
 @('vrf','https://github.com/ValveResourceFormat/ValveResourceFormat/releases/download/20.1/ValveResourceFormat.nupkg','640E8612E09654AC2E0E9C74D076E0DDC1F72EA61BA6E7F5EFEAA84565F9D3EE','vrf-lib'),
 @('valvekeyvalue','https://api.nuget.org/v3-flatcontainer/valvekeyvalue/0.70.0.499/valvekeyvalue.0.70.0.499.nupkg','1CC30EDE15E908AEC3FB15C9E917C0FEC3CF9A30EE6DB64DE1F59DBFB9130618','deps/valvekeyvalue'),
 @('lz4','https://api.nuget.org/v3-flatcontainer/k4os.compression.lz4/1.3.8/k4os.compression.lz4.1.3.8.nupkg','3A64F72703B8AA99190CBED7AA216A642CB1C928FAE2CF6DFA65DC3754FE2320','deps/k4os.compression.lz4'),
 @('zstd','https://api.nuget.org/v3-flatcontainer/zstdsharp.port/0.8.8/zstdsharp.port.0.8.8.nupkg','F6797192DEEBF4535F0601C2273E750DA0C02062E30A3E4A3C4011B9AC22403A','deps/zstdsharp.port'),
 @('valvepak','https://api.nuget.org/v3-flatcontainer/valvepak/5.0.2.177/valvepak.5.0.2.177.nupkg','EB0535746813422A94DE23632DEC1FFF30ACA5FDF2CD32FA69BB7578E84573AC','deps/valvepak'),
 @('hashing','https://api.nuget.org/v3-flatcontainer/system.io.hashing/10.0.10/system.io.hashing.10.0.10.nupkg','4CFCE1349022D31FD7E4DA18BBAD8C6D12C1EC68150A7792A910DB5776984343','deps/system.io.hashing')
)
$dlls=@('deps/k4os.compression.lz4/lib/net6.0/K4os.Compression.LZ4.dll','deps/zstdsharp.port/lib/net9.0/ZstdSharp.dll','deps/system.io.hashing/lib/net10.0/System.IO.Hashing.dll','deps/valvekeyvalue/lib/net10.0/ValveKeyValue.dll','deps/valvepak/lib/net10.0/ValvePak.dll','vrf-lib/lib/net10.0/ValveResourceFormat.dll')
if(@($dlls | Where-Object {-not (Test-Path -LiteralPath (Join-Path $ToolRoot $_))}).Count){
 foreach($package in $packages){$zip=Join-Path $ToolRoot ($package[0]+'.zip');Download-Checked $package[1] $zip $package[2];Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $ToolRoot $package[3]) -Force}
}
foreach($dll in $dlls){[Reflection.Assembly]::LoadFrom((Join-Path $ToolRoot $dll)) | Out-Null}
if(-not ('DeadlockVpk' -as [type])){
 $refs=@((Join-Path $ToolRoot 'vrf-lib/lib/net10.0/ValveResourceFormat.dll'),(Join-Path $ToolRoot 'deps/valvekeyvalue/lib/net10.0/ValveKeyValue.dll'))
 $refs+=Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter *.dll | ForEach-Object FullName
 $source=@'
using System;
using System.Linq;
using System.IO;
using System.Collections.Generic;
using System.Text;
using System.Globalization;
using ValveKeyValue;
using ValveResourceFormat;
using ValveResourceFormat.ResourceTypes;
public static class CameraRepair {
 static readonly HashSet<string> CameraNames=new HashSet<string>(new[]{"standing_pivot","crouching_pivot","portrait_camera","portrait_camera_attach","near_00","near_01","near_02","far_00","far_01","far_02","gunaim_00","gunaim_01","gunaim_02"});
 static string GameMetadata(KVObject data) => string.Join(";",data.Children.Where(p=>p.Key!="AttachmentCameraData"&&p.Key!="CitadelModelSceneData_t").Select(p=>p.Key+":"+Fingerprint(p.Value)));
 static string Fingerprint(KVObject value, string path="",HashSet<string> cameraNames=null) {
  if(path=="m_modelInfo/m_keyValueText")return "<camera-metadata>";
  if(value.IsCollection) {
   var text=new StringBuilder(value.ValueType.ToString());
   foreach(var pair in value.Children) {
    if(path=="" && pair.Key=="m_attachments") {
     foreach(var entry in pair.Value.Values)if(!(cameraNames??CameraNames).Contains((string)entry["key"]))text.Append(Fingerprint(entry));
     continue;
    }
    text.Append(pair.Key).Append(':').Append(Fingerprint(pair.Value,path.Length==0?pair.Key:path+"/"+pair.Key,cameraNames)).Append(';');
   }
   return text.ToString();
  }
  return value.ValueType+":"+value.Flag+":"+value.ToString(CultureInfo.InvariantCulture);
 }
 static (int,int) Section(string text,string name) {
  int start=text.IndexOf("\t"+name+" =");
  if(start<0)return(-1,0);
  int pos=text.IndexOf('=',start)+1;
  while(char.IsWhiteSpace(text[pos]))pos++;
  char open=text[pos],close=open=='{'?'}':']'; int depth=0;bool quoted=false,escape=false;
  for(int i=pos;i<text.Length;i++) {
   char c=text[i];if(quoted){if(escape)escape=false;else if(c=='\\')escape=true;else if(c=='"')quoted=false;continue;}
   if(c=='"'){quoted=true;continue;}if(c==open)depth++;else if(c==close&&--depth==0)return(start,i+1-start);
  }
  throw new Exception("Unclosed metadata section "+name);
 }
 static HashSet<string> RequiredCameras(Model original) {
  var required=new HashSet<string>(new[]{"standing_pivot","crouching_pivot","portrait_camera"});
  if(original.KeyValues.TryGetValue("AttachmentCameraData",out var settings))foreach(var entry in settings.Values)required.Add((string)entry["attachment_name"]);
  return required;
 }
 // Only adapt the known lobby helper: an identity child of an equivalent root.
 // Bone.BindPose is PARENT-LOCAL, not model-space. An identity child therefore
 // uses its parent's attachment coordinates without an extra rotation or offset.
 static bool CanAliasLobby(Model mod,Model original,string camera,KVObject value) {
  const string lobbyPrefix="portrait_camera_attach";
  if(!camera.StartsWith(lobbyPrefix,StringComparison.Ordinal) || !camera.Substring(lobbyPrefix.Length).All(char.IsDigit) || !RequiredCameras(original).Contains(camera) || (int)value["m_nInfluences"]!=1 || (bool)value["m_bIgnoreRotation"])return false;
  if((string)value["m_influenceNames"][0]!="attachWorld" || Math.Abs((double)value["m_influenceWeights"][0]-1)>0.00001 || (bool)value["m_bInfluenceRootTransform"][0])return false;
  var helper=original.Skeleton.Bones.FirstOrDefault(b=>b.Name=="attachWorld");
  var root=original.Skeleton.Bones.FirstOrDefault(b=>b.Name=="root_motion");
  var target=mod.Skeleton.Bones.FirstOrDefault(b=>b.Name=="root_motion");
  if(helper==null || root==null || target==null || helper.Parent!=root || root.Parent!=null || target.Parent!=null)return false;
  if(Math.Abs((double)original.Data["m_modelSkeleton"]["m_boneScaleParent"][helper.Index]-1)>0.00001 || Math.Abs((double)original.Data["m_modelSkeleton"]["m_boneScaleParent"][root.Index]-1)>0.00001 || Math.Abs((double)mod.Data["m_modelSkeleton"]["m_boneScaleParent"][target.Index]-1)>0.00001)return false;
  if(helper.Position.Length()>0.0001 || Math.Abs(System.Numerics.Quaternion.Dot(helper.Angle,System.Numerics.Quaternion.Identity))<0.99999)return false;
  return System.Numerics.Vector3.Distance(root.Position,target.Position)<0.0001 && Math.Abs(System.Numerics.Quaternion.Dot(root.Angle,target.Angle))>0.99999;
 }
 static Dictionary<string,KVObject> CameraPlan(Resource modResource,Resource originalResource,out HashSet<string> missingBones,out List<string> remapped) {
  var mod=(Model)modResource.DataBlock;var original=(Model)originalResource.DataBlock;
  var bones=new HashSet<string>(mod.Skeleton.Bones.Select(b=>b.Name));var required=RequiredCameras(original);
  missingBones=new HashSet<string>();remapped=new List<string>();var source=new Dictionary<string,KVObject>();
  foreach(var block in originalResource.Blocks.OfType<Mesh>())foreach(var entry in block.Data["m_attachments"].Values) {
   string name=(string)entry["key"];if((!CameraNames.Contains(name)&&!required.Contains(name)) || source.ContainsKey(name))continue;
   var copy=entry;var value=entry["value"];
   if(!bones.Contains("attachWorld") && CanAliasLobby(mod,original,name,value)) {
    copy=KVObject.Collection(entry.Children);var adapted=KVObject.Collection(value.Children);
    adapted["m_influenceNames"]=KVObject.Array(value["m_influenceNames"].Values.Select((v,i)=>i==0?new KVObject("root_motion"):v));
    copy["value"]=adapted;remapped.Add(name+":attachWorld->root_motion");
   }
   var attachment=new ValveResourceFormat.ResourceTypes.ModelData.Attachments.Attachment(copy);
   var absent=attachment.Where(i=>i.Weight>0 && !string.IsNullOrEmpty(i.Name) && !bones.Contains(i.Name)).Select(i=>i.Name).ToArray();
   if(absent.Length>0){if(required.Contains(name))foreach(string bone in absent)missingBones.Add(bone);continue;}
   source[name]=copy;
  }
  foreach(string camera in required)if(!original.Attachments.ContainsKey(camera))throw new Exception("Vanilla required camera attachment missing: "+camera);
  return source;
 }
 public static string Analyze(Resource modResource,Resource originalResource) {
  var mod=(Model)modResource.DataBlock;var original=(Model)originalResource.DataBlock;
  var changed=new List<string>();var oldAxis=new List<string>();var missing=new List<string>();var missingBones=new HashSet<string>();
  if(!original.Attachments.ContainsKey("standing_pivot")||!original.Attachments.ContainsKey("crouching_pivot"))return System.Text.Json.JsonSerializer.Serialize(new {status="not-hero-camera",reason="Vanilla model has no supported gameplay camera pivots"});
  foreach(string name in CameraNames.Where(n=>n!="portrait_camera"&&n!="portrait_camera_attach")) {
   if(!original.Attachments.TryGetValue(name,out var expected)||expected.Length==0)continue;
   if(!mod.Attachments.TryGetValue(name,out var actual)||actual.Length==0){missing.Add(name);continue;}
   var a=actual[0];var b=expected[0];
   double dot=Math.Abs(System.Numerics.Quaternion.Dot(a.Rotation,b.Rotation));
   if(a.Name!=b.Name||System.Numerics.Vector3.Distance(a.Offset,b.Offset)>0.02||dot<0.9999)changed.Add(name);
   if(a.Name==b.Name&&dot<0.95&&Math.Abs(b.Offset.Z)>20&&Math.Abs(a.Offset.Y)>20&&Math.Abs(a.Offset.Z)<5&&Math.Abs(Math.Abs(a.Offset.Y)-Math.Abs(b.Offset.Z))<10)oldAxis.Add(name);
  }
  string status;
  if(oldAxis.Contains("standing_pivot")&&oldAxis.Contains("crouching_pivot"))status="outdated";
  else if(missing.Contains("standing_pivot")&&missing.Contains("crouching_pivot")&&mod.KeyValues.TryGetValue("CCitadelHeroModelGameData_t",out _))status="outdated";
  else if(changed.Count==0&&missing.Count==0)status="camera-matches";
  else status="review-needed";
  CameraPlan(modResource,originalResource,out missingBones,out var remappedBones);
  var names=new HashSet<string>(mod.Skeleton.Bones.Select(b=>b.Name));
  bool invalidLobby=remappedBones.Any(mapping=>{string name=mapping.Substring(0,mapping.IndexOf(':'));return !mod.Attachments.TryGetValue(name,out var lobby) || lobby.Any(i=>i.Weight>0&&!names.Contains(i.Name));});
  if(status=="camera-matches"&&invalidLobby)status="outdated";
  if((status=="outdated" || status=="camera-matches")&&missingBones.Count>0)status="unsupported";
  return System.Text.Json.JsonSerializer.Serialize(new {status,changed,missing,oldAxis,missingBones,remappedBones,reason=status=="outdated"?(oldAxis.Count>0?"Known old-axis camera signature":"Known lobby camera reference requires root binding adaptation"):status=="unsupported"?"Required camera bones are absent and no verified binding adaptation applies":status=="review-needed"?"Camera differs without a recognized old-axis signature; left unchanged":"Gameplay camera attachments match current vanilla"});
 }
 public static void Run(Resource mod, Resource orig, string output) {
  var cameraNames=new HashSet<string>(CameraNames);cameraNames.UnionWith(RequiredCameras((Model)orig.DataBlock));
  var snapshots=new Dictionary<int,string>();
  for(int i=0;i<mod.Blocks.Count;i++)if(mod.Blocks[i] is Mesh mesh)snapshots[i]=Fingerprint(mesh.Data,cameraNames:cameraNames);
  string dataSnapshot=Fingerprint(((Model)mod.DataBlock).Data);
  string metadataSnapshot=GameMetadata(((Model)mod.DataBlock).KeyValues);
  var source=CameraPlan(mod,orig,out var missingBones,out var remappedBones);
  if(missingBones.Count>0)throw new Exception("Camera bones missing from mod: "+string.Join(", ",missingBones));
  foreach(string mapping in remappedBones)Console.WriteLine("Adapted lobby binding: "+mapping);
  Console.WriteLine("Original camera attachments: " + source.Count);
  if(!source.ContainsKey("standing_pivot")||!source.ContainsKey("crouching_pivot"))throw new Exception("No supported vanilla camera pivots");
  int count=0;
  foreach(var block in mod.Blocks.OfType<Mesh>()) {
   var array = block.Data["m_attachments"];
   var seen = new HashSet<string>();
   foreach(var entry in array.Values) {
    string name=(string)entry["key"];
    if(source.TryGetValue(name, out var replacement)) { entry["value"] = replacement["value"]; seen.Add(name); count++; }
   }
   foreach(var pair in source) if(!seen.Contains(pair.Key)) { array.Add(pair.Value); count++; }
  }
  if(count==0)throw new Exception("No embedded mesh attachment blocks found; unsupported model");
  var data = ((Model)mod.DataBlock).Data;
  string current = (string)data["m_modelInfo"]["m_keyValueText"];
  string vanilla = (string)((Model)orig.DataBlock).Data["m_modelInfo"]["m_keyValueText"];
  foreach(string section in new[]{"AttachmentCameraData","CitadelModelSceneData_t"}) {
   var src=Section(vanilla,section);if(src.Item1<0)throw new Exception("Missing original "+section);
   var old=Section(current,section);if(old.Item1>=0)current=current.Remove(old.Item1,old.Item2);
   int insertion=current.IndexOf("\tBoneConstraintList =");if(insertion<0)insertion=current.LastIndexOf('}');if(insertion<0)throw new Exception("Missing insertion boundary");
   current=current.Insert(insertion,vanilla.Substring(src.Item1,src.Item2)+"\n");
  }
  if(!current.Contains("AttachmentCameraData") || !current.Contains("portrait_camera")) throw new Exception("Missing lobby camera metadata");
  data["m_modelInfo"]["m_keyValueText"] = current;
  byte[] originalBytes=File.ReadAllBytes(mod.FileName);
  using(var stream=File.Create(output)) using(var writer=new BinaryWriter(stream)) {
   int n=mod.Blocks.Count;
   writer.Write(0u); writer.Write((ushort)12); writer.Write(BitConverter.ToUInt16(originalBytes,6));
   writer.Write(8u); writer.Write((uint)n);
   writer.Write(new byte[n*12]);
   for(int i=0;i<n;i++) {
    var block=mod.Blocks[i];
    while(stream.Position%16!=0)writer.Write((byte)0);
    long offset=stream.Position;
    string type=block.Type.ToString();
    if(type=="MDAT" || type=="DATA") block.Serialize(stream);
    else writer.Write(originalBytes,(int)block.Offset,(int)block.Size);
    long endPosition=stream.Position;
    stream.Position=16+i*12;
    writer.Write(Encoding.ASCII.GetBytes(type));
    writer.Write((uint)(offset-(16+i*12+4)));
    writer.Write((uint)(endPosition-offset));
    stream.Position=endPosition;
   }
   long length=stream.Length;stream.Position=0;writer.Write((uint)length);
  }
  Console.WriteLine("Replaced/added camera attachments: " + count);
  using(var check=new Resource()) {
   check.Read(output);
   var checkedModel=(Model)check.DataBlock;
   var checkedBones=new HashSet<string>(checkedModel.Skeleton.Bones.Select(b=>b.Name));
   foreach(string name in RequiredCameras((Model)orig.DataBlock)) {
    if(!checkedModel.Attachments.TryGetValue(name,out var attachment))throw new Exception("Required camera missing after repair: "+name);
    if(attachment.Any(i=>i.Weight>0&&!string.IsNullOrEmpty(i.Name)&&!checkedBones.Contains(i.Name)))throw new Exception("Invalid camera bone after repair: "+name);
   }
   if(check.Blocks.Count!=mod.Blocks.Count)throw new Exception("Block count changed");
   var checkData=((Model)check.DataBlock).Data;
   if(Fingerprint(checkData)!=dataSnapshot)throw new Exception("Non-camera model data changed");
   if(GameMetadata(((Model)check.DataBlock).KeyValues)!=metadataSnapshot)throw new Exception("Non-camera game metadata changed");
   string checkText=(string)checkData["m_modelInfo"]["m_keyValueText"];
   foreach(var section in new[]{"AttachmentCameraData","CitadelModelSceneData_t"}) {
    var expected=Section(vanilla,section);var actual=Section(checkText,section);
    if(actual.Item1<0||vanilla.Substring(expected.Item1,expected.Item2)!=checkText.Substring(actual.Item1,actual.Item2))throw new Exception("Camera metadata verification failed");
   }
   byte[] saved=File.ReadAllBytes(output);
   for(int i=0;i<check.Blocks.Count;i++) {
    var old=mod.Blocks[i];var block=check.Blocks[i];
    if(block.Type!=old.Type)throw new Exception("Block type changed");
    if(block is Mesh mesh) {
     if(Fingerprint(mesh.Data,cameraNames:cameraNames)!=snapshots[i])throw new Exception("Mesh geometry or material data changed");
     foreach(var entry in mesh.Data["m_attachments"].Values) {
      string name=(string)entry["key"];
      if(source.TryGetValue(name,out var reference) && Fingerprint(entry["value"])!=Fingerprint(reference["value"]))throw new Exception("Camera attachment verification failed: "+name);
     }
    }else if(block.Type.ToString()!="DATA") {
     if(block.Size!=old.Size || !saved.AsSpan((int)block.Offset,(int)block.Size).SequenceEqual(originalBytes.AsSpan((int)old.Offset,(int)old.Size)))throw new Exception("Unrelated resource block changed");
    }
   }
  }
  Console.WriteLine("Reopened model verified: camera metadata, attachments, bones and preserved resource data.");
 }
}
public sealed class DeadlockVpk {
 sealed class Entry {
  public string Path="";public uint Crc,Offset,Length;public ushort Archive;public byte[] Preload=Array.Empty<byte>();
 }
 readonly string file;
 readonly int headerSize;
 readonly uint treeSize;
 readonly Dictionary<string,Entry> entries=new Dictionary<string,Entry>(StringComparer.OrdinalIgnoreCase);
 public bool Signed {get;private set;}
 public bool IsSplit {get;private set;}
 public string[] Paths => entries.Keys.ToArray();
 static readonly uint[] CrcTable=Enumerable.Range(0,256).Select(n=>{uint c=(uint)n;for(int i=0;i<8;i++)c=(c&1)!=0?0xedb88320u^(c>>1):c>>1;return c;}).ToArray();
 static uint Update(uint crc,byte[] data,int offset,int count){for(int i=offset;i<offset+count;i++)crc=CrcTable[(crc^data[i])&255]^(crc>>8);return crc;}
 static string CString(BinaryReader reader){
  var bytes=new List<byte>();
  while(true){if(reader.BaseStream.Position>=reader.BaseStream.Length)throw new InvalidDataException("Truncated VPK directory");byte b=reader.ReadByte();if(b==0)break;bytes.Add(b);if(bytes.Count>32768)throw new InvalidDataException("VPK name too long");}
  return Encoding.UTF8.GetString(bytes.ToArray());
 }
 public DeadlockVpk(string path){
  file=System.IO.Path.GetFullPath(path);
  using(var stream=File.OpenRead(file))using(var reader=new BinaryReader(stream)){
   if(stream.Length<12||reader.ReadUInt32()!=0x55aa1234)throw new InvalidDataException("Invalid VPK signature");
   uint version=reader.ReadUInt32();treeSize=reader.ReadUInt32();
   if(version!=1&&version!=2)throw new InvalidDataException("Unsupported VPK version");headerSize=version==1?12:28;
   if(stream.Length<headerSize||treeSize>128*1024*1024||treeSize>stream.Length-headerSize)throw new InvalidDataException("Invalid VPK tree length");
   if(version==2){reader.ReadUInt32();reader.ReadUInt32();reader.ReadUInt32();Signed=reader.ReadUInt32()!=0;}
   byte[] tree=reader.ReadBytes((int)treeSize);
   using(var treeStream=new MemoryStream(tree))using(var tr=new BinaryReader(treeStream)){
    string ext,dir,name;
    while((ext=CString(tr)).Length>0)while((dir=CString(tr)).Length>0)while((name=CString(tr)).Length>0){
     var e=new Entry();e.Path=(dir==" "?"":dir+"/")+name+"."+ext;
     if(e.Path.Contains("\\")||e.Path.StartsWith("/")||e.Path.Split('/').Contains(".."))throw new InvalidDataException("Unsafe VPK resource path");
     e.Crc=tr.ReadUInt32();int preload=tr.ReadUInt16();e.Archive=tr.ReadUInt16();e.Offset=tr.ReadUInt32();e.Length=tr.ReadUInt32();
     if(tr.ReadUInt16()!=65535)throw new InvalidDataException("Bad VPK entry terminator");
     e.Preload=tr.ReadBytes(preload);if(e.Preload.Length!=preload)throw new InvalidDataException("Truncated preload");
     if(e.Archive!=32767)IsSplit=true;
     if(entries.TryGetValue(e.Path,out var prior)){
      if(prior.Crc!=e.Crc||prior.Length+prior.Preload.Length!=e.Length+e.Preload.Length||!ReadEntry(prior).AsSpan().SequenceEqual(ReadEntry(e)))throw new InvalidDataException("Conflicting duplicate resource: "+e.Path);
     }else entries.Add(e.Path,e);
    }
   }
  }
 }
 public bool Contains(string path)=>entries.ContainsKey(path);
 string DataFile(Entry entry){
  if(entry.Archive==32767)return file;
  string stem=System.IO.Path.GetFileNameWithoutExtension(file);
  if(!stem.EndsWith("_dir",StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Split archive requires a _dir.vpk index");
  return System.IO.Path.Combine(System.IO.Path.GetDirectoryName(file)!,stem.Substring(0,stem.Length-4)+"_"+entry.Archive.ToString("D3")+".vpk");
 }
 FileStream OpenPayload(Entry entry){
  var stream=File.OpenRead(DataFile(entry));
  long start=entry.Archive==32767?(long)headerSize+treeSize+entry.Offset:entry.Offset;
  if(start<0||start>stream.Length||entry.Length>stream.Length-start){stream.Dispose();throw new InvalidDataException("Resource outside archive: "+entry.Path);}
  stream.Position=start;return stream;
 }
 byte[] ReadEntry(Entry e){
  long length=(long)e.Preload.Length+e.Length;if(length>512*1024*1024)throw new InvalidDataException("Resource exceeds 512 MiB safety limit");
  byte[] data=new byte[(int)length];e.Preload.CopyTo(data,0);
  using(var input=OpenPayload(e))input.ReadExactly(data.AsSpan(e.Preload.Length));
  if((Update(uint.MaxValue,data,0,data.Length)^uint.MaxValue)!=e.Crc)throw new InvalidDataException("CRC mismatch: "+e.Path);
  return data;
 }
 public byte[] Read(string path){if(!entries.TryGetValue(path,out var e))throw new FileNotFoundException("VPK model not found: "+path);return ReadEntry(e);}
 byte[] Transfer(Entry e,Stream output){
  using(var digest=System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256)){
   uint crc=uint.MaxValue;byte[] buffer=new byte[1024*1024];
   if(e.Preload.Length>0){output?.Write(e.Preload);digest.AppendData(e.Preload);crc=Update(crc,e.Preload,0,e.Preload.Length);}
   using(var input=OpenPayload(e)){
    long remaining=e.Length;
    while(remaining>0){int n=input.Read(buffer,0,(int)Math.Min(buffer.Length,remaining));if(n==0)throw new EndOfStreamException("Truncated resource "+e.Path);output?.Write(buffer,0,n);digest.AppendData(buffer,0,n);crc=Update(crc,buffer,0,n);remaining-=n;}
   }
   if((crc^uint.MaxValue)!=e.Crc)throw new InvalidDataException("CRC mismatch: "+e.Path);
   return digest.GetHashAndReset();
  }
 }
 static void String(BinaryWriter writer,string text){writer.Write(Encoding.UTF8.GetBytes(text));writer.Write((byte)0);}
 public static void Pack(string source,string destination,Dictionary<string,string> replacements){
  var original=new DeadlockVpk(source);
  if(original.Signed||original.IsSplit)throw new InvalidDataException("Signed or split mods are not rewritten");
  if(replacements.Count==0)throw new InvalidDataException("No selected repairs");
  foreach(string path in replacements.Keys)if(!original.Contains(path))throw new InvalidDataException("Replacement absent from source");
  var payload=new List<Entry>();var replacementBytes=new Dictionary<string,byte[]>(StringComparer.OrdinalIgnoreCase);
  foreach(var pair in replacements)replacementBytes.Add(pair.Key,File.ReadAllBytes(pair.Value));
  using(var tree=new MemoryStream())using(var tw=new BinaryWriter(tree)){
   ulong offset=0;
   var groups=original.entries.Values.GroupBy(e=>System.IO.Path.GetExtension(e.Path).Substring(1)).OrderBy(g=>g.Key,StringComparer.Ordinal);
   foreach(var extension in groups){
    String(tw,extension.Key);
    foreach(var directory in extension.GroupBy(e=>e.Path.Contains('/')?e.Path.Substring(0,e.Path.LastIndexOf('/')):" ").OrderBy(g=>g.Key,StringComparer.Ordinal)){
     String(tw,directory.Key);
     foreach(var e in directory.OrderBy(e=>e.Path,StringComparer.Ordinal)){
      string basename=System.IO.Path.GetFileNameWithoutExtension(e.Path);String(tw,basename);
      long length=replacementBytes.TryGetValue(e.Path,out var bytes)?bytes.Length:(long)e.Preload.Length+e.Length;
      if(offset+(ulong)length>uint.MaxValue)throw new InvalidDataException("Output would exceed single-VPK 4 GiB offset limit");
      uint crc=bytes==null?e.Crc:Update(uint.MaxValue,bytes,0,bytes.Length)^uint.MaxValue;
      tw.Write(crc);tw.Write((ushort)0);tw.Write((ushort)32767);tw.Write((uint)offset);tw.Write((uint)length);tw.Write((ushort)65535);
      payload.Add(e);offset+=(ulong)length;
     }
     String(tw,"");
    }
    String(tw,"");
   }
   String(tw,"");tw.Flush();
   using(var output=File.Create(destination))using(var writer=new BinaryWriter(output)){
    writer.Write(0x55aa1234u);writer.Write(1u);writer.Write(checked((uint)tree.Length));tree.Position=0;tree.CopyTo(output);
    foreach(var entry in payload){if(replacementBytes.TryGetValue(entry.Path,out var bytes))output.Write(bytes);else original.Transfer(entry,output);}
   }
  }
  var check=new DeadlockVpk(destination);
  if(check.entries.Count!=original.entries.Count)throw new InvalidDataException("Repacked file count changed");
  foreach(var entry in original.entries.Values){
   if(replacementBytes.TryGetValue(entry.Path,out var bytes)){
    if(!check.Read(entry.Path).AsSpan().SequenceEqual(bytes))throw new InvalidDataException("Replacement verification failed: "+entry.Path);
   }else if(!original.Transfer(entry,null).AsSpan().SequenceEqual(check.Transfer(check.entries[entry.Path],null)))throw new InvalidDataException("Unrelated resource changed: "+entry.Path);
  }
 }
}

'@
 Add-Type -ReferencedAssemblies $refs -TypeDefinition $source
}
$run=Join-Path $OutputRoot ('batch-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$batchPath=Join-Path $run 'batch-report.json'
$batch=[pscustomobject]@{schema=2;mode=$Mode;game=$GamePath;createdUtc=[DateTime]::UtcNow.ToString('o');gameVerification='pending';mods=@()}
# Persist only actionable repair records, not a log for every scan/run.
function Save-Batch {
 if(@($batch.mods | Where-Object repairReport).Count){Write-Json $batchPath $batch}
}
$manifestPath=Join-Path $addons '.dmm.json';$manifest=if(Test-Path -LiteralPath $manifestPath){Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json}else{$null}
$names=@{};$statePath=Join-Path $env:APPDATA 'dev.stormix.deadlock-mod-manager/state.json'
if(Test-Path -LiteralPath $statePath){try{$outer=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json;$state=$outer.'local-config' | ConvertFrom-Json;foreach($mod in $state.state.localMods){$names[$mod.remoteId]=$mod.name}}catch{Write-Warning 'Cannot read display names; using manifest IDs.'}}
$vanillaFile=Join-Path $GamePath 'game/citadel/pak01_dir.vpk';$vanillaHash=Hash $vanillaFile
$vanilla=[DeadlockVpk]::new($vanillaFile)
$files=@(Get-ChildItem -LiteralPath $addons -File -Filter *.vpk | Where-Object {$_.Name -match '^pak\d+_dir\.vpk$'} | Sort-Object Name)
if($Vpk){$files=@($files | Where-Object {$_.Name -in $Vpk});if(-not $files.Count){throw 'No enabled VPK matches the filter.'}}
Write-Host "Game: $GamePath";Write-Host "Found $($files.Count) enabled VPK archives."
$number=0
foreach($file in $files){
 $number++;$ids=@();if($manifest){$ids=@($manifest.mods.PSObject.Properties | Where-Object {$_.Value.enabled -and $_.Value.currentVpks -contains $file.Name} | ForEach-Object Name)}
 $name=(@($ids | ForEach-Object {if($names.ContainsKey($_)){$names[$_]}else{$_}}) -join ', ');if(-not $name){$name=$file.Name}
 Write-Host "[$number/$($files.Count)] $name ($($file.Name))"
 $folder=$null
 $item=[pscustomobject]@{vpk=$file.Name;name=$name;modIds=$ids;status='scanning';models=@();repairReport=$null;error=$null};$batch.mods+=@($item)
 try{
  if($file.LinkType){throw 'Linked archives are unsupported.'}
  $before=Hash $file.FullName;$archive=[DeadlockVpk]::new($file.FullName)
  $candidates=@($archive.Paths | Where-Object {$_ -match '^models/heroes_(?:wip|staging)/[^/]+/[^/]+\.vmdl_c$'})
  if(-not $candidates.Count){$item.status='no-hero-model';continue}
  if($archive.Signed -or $archive.IsSplit){$item.status='unsupported-archive';$item.error='Signed/split mod archive: read-only inspection only.';continue}
  $folder=Join-Path $run $file.BaseName;New-Item -ItemType Directory -Path $folder -Force | Out-Null
  $replacements=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase);$blocked=$false
  $modelNumber=0
  foreach($modelPath in $candidates){
   $reference=$modelPath
   if(-not $vanilla.Contains($reference)){
    $reference=$modelPath -replace '(_backup|_original|_base)\.vmdl_c$','.vmdl_c'
    if($reference -eq $modelPath -or -not $vanilla.Contains($reference)){$item.models+=@([pscustomobject]@{model=$modelPath;reference=$null;status='no-vanilla-reference';reason='Unmatched custom model; left unchanged.'});continue}
   }
   $index=$modelNumber;$modelNumber++
   $modFile=Join-Path $folder "mod-$index.vmdl_c";$origFile=Join-Path $folder "vanilla-$index.vmdl_c";$fixedFile=Join-Path $folder "fixed-$index.vmdl_c"
   [IO.File]::WriteAllBytes($modFile,$archive.Read($modelPath));[IO.File]::WriteAllBytes($origFile,$vanilla.Read($reference))
   $modResource=[ValveResourceFormat.Resource]::new();$origResource=[ValveResourceFormat.Resource]::new()
   try{
    $modResource.Read($modFile);$origResource.Read($origFile)
    $analysis=[CameraRepair]::Analyze($modResource,$origResource) | ConvertFrom-Json
    $item.models+=@([pscustomobject]@{model=$modelPath;reference=$reference;status=$analysis.status;reason=$analysis.reason;details=$analysis})
    if($analysis.status -eq 'unsupported'){$blocked=$true}
    if($analysis.status -eq 'outdated' -and $Mode -ne 'Scan'){
     [CameraRepair]::Run($modResource,$origResource,$fixedFile)
     $replacements.Add($modelPath,$fixedFile)
    }
   }finally{$modResource.Dispose();$origResource.Dispose()}
  }
  if((Hash $file.FullName) -ne $before){throw 'Mod changed during scanning; retry with Mod Manager idle.'}
  if($blocked){$item.status='unsupported';continue}
  $outdated=@($item.models | Where-Object status -eq 'outdated')
  if(-not $outdated.Count){
   $item.status=if(@($item.models | Where-Object status -eq 'review-needed').Count){'review-needed'}elseif(@($item.models | Where-Object status -eq 'camera-matches').Count){'camera-matches'}else{'no-supported-camera-model'};continue
  }
  $item.status='outdated';if($Mode -eq 'Scan'){continue}
  $backup=Join-Path $folder 'original.vpk';Copy-Item -LiteralPath $file.FullName -Destination $backup
  if((Hash $backup) -ne $before -or (Hash $file.FullName) -ne $before){throw 'Mod changed during backup.'}
  if((Hash $vanillaFile) -ne $vanillaHash){throw 'Vanilla index changed during scanning; wait for Steam to finish updating.'}
  $fixed=Join-Path $folder 'fixed_dir.vpk';[DeadlockVpk]::Pack($backup,$fixed,$replacements)
  $record=[pscustomobject]@{schema=1;game=$GamePath;vpk=$file.Name;backup=$backup;fixed=$fixed;originalSha256=$before;fixedSha256=(Hash $fixed);models=@($replacements.Keys);gameVerification='pending'}
  $recordPath=Join-Path $folder 'report.json';Write-Json $recordPath $record;$item.repairReport=$recordPath;$item.status='prepared';Save-Batch
  if($Mode -eq 'Repair'){
   if(Get-Process -Name deadlock,citadel -ErrorAction SilentlyContinue){$item.status='pending-game-exit'}else{Replace-Mod $record 'Install';$item.status='installed'}
  }
 }catch{$item.status='failed';$item.error=$_.Exception.Message;Write-Warning "$($file.Name): $($item.error)"}
 finally{
  Save-Batch
  if($folder -and -not $item.repairReport -and (Test-Path -LiteralPath $folder)){
   $resolvedFolder=[IO.Path]::GetFullPath($folder)
   if([IO.Path]::GetDirectoryName($resolvedFolder) -ne [IO.Path]::GetFullPath($run)){throw 'Unexpected temporary work path; refusing cleanup.'}
   Remove-Item -LiteralPath $resolvedFolder -Recurse -Force
  }
 }
}
$batch.mods | Select-Object vpk,name,status,error | Format-Table -AutoSize | Out-Host
foreach($item in $batch.mods){foreach($model in $item.models){
 if($model.status -in @('outdated','unsupported','review-needed')){Write-Host "$($item.vpk) / $($model.model): $($model.reason)"}
}}
if(Test-Path -LiteralPath $batchPath){Write-Host "Repair record: $batchPath"}
elseif(Test-Path -LiteralPath $run){[IO.Directory]::Delete($run)}
Write-Host 'File checks are not in-game verification. Restart and test the lobby, crouching, aiming, abilities and respawn.'
