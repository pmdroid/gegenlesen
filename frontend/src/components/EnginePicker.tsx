import { ENGINE_IDS, ENGINE_LABELS, type EngineId } from "../engines";

type Props = {
  label: string;
  value: EngineId;
  onChange: (engine: EngineId) => void;
  disabled?: boolean;
  /** When set, only these engines appear in the dropdown. */
  engines?: readonly EngineId[];
};

export function EnginePicker({ label, value, onChange, disabled, engines }: Props) {
  const options = engines ?? ENGINE_IDS;
  return (
    <label className="engine-picker">
      {label}
      <select value={value} disabled={disabled} onChange={(event) => onChange(event.target.value as EngineId)}>
        {options.map((id) => (
          <option key={id} value={id}>
            {ENGINE_LABELS[id]}
          </option>
        ))}
      </select>
    </label>
  );
}
