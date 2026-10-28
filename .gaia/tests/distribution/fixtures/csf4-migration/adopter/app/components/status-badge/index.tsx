export type Status = 'active' | 'archived' | 'paused';

type StatusBadgeProps = {
  status: Status;
};

const StatusBadge = ({status}: StatusBadgeProps) => (
  <span className="m-4 inline-block rounded-sm border px-2 py-1 text-sm">
    {status}
  </span>
);

export default StatusBadge;
