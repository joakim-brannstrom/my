/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.signal_theory.kalman;

struct KalmanFilter {
    /**
     *
     * Params:
     *  meaE = measurement uncertainty. How much the measurements is expected to vary.
     *  estE = estimation uncertainty. Adjusted over time by the Kalman Filter but can be initialized to mea_e.
     *  q = process variance. usually a small number [0.001, 1]. How fast the measurement moves. Recommended is 0.001, tune as needed.
     */
    this(double meaE, double estE, double q) {
        this.errMeasure = meaE;
        this.errEstimate = estE;
        this.q = q;
    }

    void updateEstimate(double mea) {
        import std.math : abs;

        kalmanGain = errEstimate / (errEstimate + errMeasure);
        currentEstimate = lastEstimate + kalmanGain * (mea - lastEstimate);
        errEstimate = (1.0 - kalmanGain) * errEstimate + abs(lastEstimate - currentEstimate) * q;
        lastEstimate = currentEstimate;
    }

    void setMeasurementError(double meaE) {
        this.errMeasure = meaE;
    }

    void setEstimateError(double estE) {
        this.errEstimate = estE;
    }

    void setProcessNoise(double q) {
        this.q = q;
    }

    double getKalmanGain() {
        return kalmanGain;
    }

    double getEstimateError() {
        return errEstimate;
    }

private:
    double errMeasure;
    double errEstimate;
    double q;
    double currentEstimate;
    double lastEstimate;
    double kalmanGain;
}
