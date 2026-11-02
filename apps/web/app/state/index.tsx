/* eslint-disable canonical/filename-match-exported -- an index module is named by its folder */
import type {ReactNode} from 'react';

type StateProps = {
  children: ReactNode;
};

const State = ({children}: StateProps) => <>{children}</>;

export default State;
