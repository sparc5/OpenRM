//
//  DisclaimerView.swift
//  OpenRM
//

import SwiftUI

struct DisclaimerView: View {
    var onAccept: () -> Void

    @State private var scrolledToBottom = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Important Legal Disclaimer")
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 30)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("EXPERIMENTAL / RESEARCH SOFTWARE")
                        .font(.headline)

                    Text("""
                    This application ("OpenRM") is experimental, open-source research software. \
                    It is NOT a medical device, has NOT been reviewed or approved by the U.S. Food \
                    and Drug Administration (FDA) or any other regulatory body, and is NOT intended \
                    for diagnostic, therapeutic, or clinical use of any kind.
                    """)

                    Text("NO THERAPEUTIC USE")
                        .font(.headline)

                    Text("""
                    You agree that you will NOT use this software to guide, inform, or replace any \
                    medical treatment, therapy, or clinical decision-making. This includes, but is \
                    not limited to, the adjustment of CPAP/BiPAP pressure settings, sleep therapy \
                    parameters, or any other equipment configuration that could affect your health \
                    or safety.
                    """)

                    Text("ASSUMPTION OF RISK & WAIVER OF LIABILITY")
                        .font(.headline)

                    Text("""
                    By using this software, you acknowledge and agree that:

                    1. You use this software entirely at your own risk.

                    2. The authors, contributors, and maintainers of this software provide it \
                    "AS IS" without warranty of any kind, express or implied, including but not \
                    limited to warranties of merchantability, fitness for a particular purpose, \
                    or non-infringement.

                    3. In no event shall the authors, contributors, or maintainers be liable for \
                    any claim, damages, or other liability — whether in an action of contract, \
                    tort, or otherwise — arising from, out of, or in connection with the software \
                    or the use or other dealings in the software, including any personal injury, \
                    property damage, or damage to equipment.

                    4. You waive and release any and all claims, actions, or causes of action \
                    against the authors, contributors, and maintainers for any harm, loss, or \
                    damage of any kind arising from your use of this software.
                    """)

                    Text("EQUIPMENT RISK")
                        .font(.headline)

                    Text("""
                    This software may interact with medical or electronic equipment. You \
                    acknowledge that such interaction carries inherent risks, including but not \
                    limited to equipment malfunction, misconfiguration, data corruption, or \
                    voiding of manufacturer warranties. You accept full responsibility for any \
                    consequences of connecting this software to your equipment.
                    """)

                    Color.clear.frame(height: 1)
                        .onAppear { scrolledToBottom = true }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: .infinity)

            Button(action: onAccept) {
                Text("I Agree")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(scrolledToBottom ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(!scrolledToBottom)
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .preferredColorScheme(.dark)
    }
}
