program SampleProject;

uses
  Vcl.Forms,
  UnitSample in 'UnitSample.pas' {FormSample},
  uSDL3CustomThreadedBase in 'uSDL3CustomThreadedBase.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormSample, FormSample);
  Application.Run;
end.
