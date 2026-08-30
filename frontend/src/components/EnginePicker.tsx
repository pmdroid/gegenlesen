import { ENGINE_IDS, ENGINE_LABELS, type EngineId } from "../engines";

type Props = {
  label: string;
  value: EngineId;
  onChange: (engine: EngineId) => void;
  disabled?: boolean;
};

export function EnginePicker({ label, value, onChange, disabled }: Props) {
  return (
    <label className="engine-picker">
      {label}
      <select value={value} disabled={disabled} onChange={(event) => onChange(event.target.value as EngineId)}>
        {ENGINE_IDS.map((id) => (
          <option key={id} value={id}>
            {ENGINE_LABELS[id]}
          </option>
        ))}
      </select>
    </label>
  );
}
