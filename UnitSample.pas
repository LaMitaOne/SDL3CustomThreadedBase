unit UnitSample;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  uSDL3CustomThreadedBase;

type
  TFormSample = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FSDL3View: TSDL3CustomThreadedBase;
    btnStart: TButton;
    btnStop: TButton;
    btnToggleFPS: TButton;
    tbFPS: TTrackBar;
    lblFPS: TLabel;
    FPSTimer: TTimer;

    procedure OnStartClick(Sender: TObject);
    procedure OnStopClick(Sender: TObject);
    procedure OnToggleFPSClick(Sender: TObject);
    procedure OnFPSTracking(Sender: TObject);
    procedure OnFPSTimer(Sender: TObject);
  public
    { Public-Deklarationen }
  end;

var
  FormSample: TFormSample;

implementation

{$R *.dfm}

procedure TFormSample.FormCreate(Sender: TObject);
begin
  Caption := 'SDL3 Custom Threaded Base Sample';

  // 1. Create the Custom SDL3 Component
  FSDL3View := TSDL3CustomThreadedBase.Create(Self);
  FSDL3View.Active := False;
  FSDL3View.TargetFPS := 60;

  // 2. Create Start Button
  btnStart := TButton.Create(Self);
  btnStart.Parent := Self;
  btnStart.Caption := 'Start Animation';
  btnStart.Width := 100;
  btnStart.Left := 20;
  btnStart.Top := 15;
  btnStart.OnClick := OnStartClick;

  // 3. Create Stop Button
  btnStop := TButton.Create(Self);
  btnStop.Parent := Self;
  btnStop.Caption := 'Stop Animation';
  btnStop.Width := 100;
  btnStop.Left := 130;
  btnStop.Top := 15;
  btnStop.OnClick := OnStopClick;

  // 4. Create FPS Label
  lblFPS := TLabel.Create(Self);
  lblFPS.Parent := Self;
  lblFPS.Caption := 'Target: 60 | Real: 0 FPS';
  lblFPS.Left := 400;
  lblFPS.Top := 20;
  lblFPS.Width := 200;
  lblFPS.Font.Size := 10;

  // 5. Create FPS TrackBar
  tbFPS := TTrackBar.Create(Self);
  tbFPS.Parent := Self;
  tbFPS.Min := 1;
  tbFPS.Max := 5000;
  tbFPS.Position := 60;
  tbFPS.Width := 250;
  tbFPS.Left := 400;
  tbFPS.Top := 35;
  tbFPS.OnChange := OnFPSTracking;

  // 6. Create FPS Update Timer
  FPSTimer := TTimer.Create(Self);
  FPSTimer.Interval := 500;
  FPSTimer.OnTimer := OnFPSTimer;
  FPSTimer.Enabled := True;
end;

procedure TFormSample.FormDestroy(Sender: TObject);
begin
  // Owned components are freed automatically
end;

procedure TFormSample.OnStartClick(Sender: TObject);
begin
  if Assigned(FSDL3View) then
    FSDL3View.Active := True;
end;

procedure TFormSample.OnStopClick(Sender: TObject);
begin
  if Assigned(FSDL3View) then
    FSDL3View.Active := False;
end;

procedure TFormSample.OnToggleFPSClick(Sender: TObject);
begin
  if Assigned(FSDL3View) then
  begin
    if FSDL3View.TargetFPS = 60 then
      FSDL3View.TargetFPS := 120
    else if FSDL3View.TargetFPS = 120 then
      FSDL3View.TargetFPS := 30
    else
      FSDL3View.TargetFPS := 60;

    if Assigned(tbFPS) then
      tbFPS.Position := FSDL3View.TargetFPS;
  end;
end;

procedure TFormSample.OnFPSTracking(Sender: TObject);
begin
  if Assigned(FSDL3View) and Assigned(tbFPS) then
  begin
    FSDL3View.TargetFPS := Round(tbFPS.Position);
  end;
end;

procedure TFormSample.OnFPSTimer(Sender: TObject);
begin
  if Assigned(FSDL3View) and Assigned(lblFPS) then
  begin
    lblFPS.Caption := Format('Target: %d | Real: %d FPS', [FSDL3View.TargetFPS, FSDL3View.RealFPS]);
  end;
end;

end.
